//! gitchecker — a local service that periodically discovers git repositories and
//! reports their status (uncommitted / unpushed / behind origin) over HTTP.

mod api;
mod config;
mod db;
mod fetch;
mod model;
mod scan;
#[cfg(windows)]
mod service;
mod status;

use crate::api::AppState;
use crate::config::Config;
use crate::db::Db;
use crate::status::{compute_status, now_unix};
use anyhow::Result;
use std::future::Future;
use std::sync::Arc;
use tokio::sync::{Notify, Semaphore};
use tokio::task::JoinSet;
use tokio::time::{interval, timeout};
use tracing_subscriber::{prelude::*, EnvFilter};

/// Max concurrent per-repo operations (status checks / fetches).
const CONCURRENCY: usize = 8;

fn main() -> Result<()> {
    // When the Windows Service Control Manager launches us (the install script
    // registers the binary as `gitchecker.exe --service`), hand control to the
    // service dispatcher instead of running in the foreground.
    #[cfg(windows)]
    if std::env::args().any(|a| a == "--service") {
        return service::run();
    }

    // Foreground / console mode: run until the process is killed (Ctrl-C).
    run_server(std::future::pending::<()>())
}

/// Build the runtime and drive the server until `shutdown` resolves. Shared by
/// console mode and the Windows service entry point.
///
/// Single-threaded runtime: this service is idle the vast majority of the time,
/// so one worker thread is plenty. CPU-bound git work is still offloaded to the
/// blocking pool via `spawn_blocking`, keeping the API responsive.
pub fn run_server<F>(shutdown: F) -> Result<()>
where
    F: Future<Output = ()> + Send + 'static,
{
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    rt.block_on(serve(shutdown))
}

async fn serve<F>(shutdown: F) -> Result<()>
where
    F: Future<Output = ()> + Send + 'static,
{
    tracing_subscriber::registry()
        .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .with(tracing_subscriber::fmt::layer())
        .init();

    let config_path = config::config_path()?;
    let cfg = Arc::new(config::load_or_init(&config_path)?);
    tracing::info!(path = %config_path.display(), "loaded config");

    let db = Db::open(&config::db_path()?)?;

    let check_notify = Arc::new(Notify::new());
    let fetch_notify = Arc::new(Notify::new());

    // Background loops.
    tokio::spawn(scan_loop(
        db.clone(),
        cfg.clone(),
        check_notify.clone(),
        fetch_notify.clone(),
    ));
    tokio::spawn(check_loop(db.clone(), cfg.clone(), check_notify.clone()));
    if cfg.fetch_enabled {
        tokio::spawn(fetch_loop(
            db.clone(),
            cfg.clone(),
            fetch_notify,
            check_notify.clone(),
        ));
    } else {
        tracing::info!("fetch disabled in config; 'behind origin' may be stale");
    }

    // HTTP server.
    let state = AppState {
        db,
        cfg: cfg.clone(),
    };
    let listener = tokio::net::TcpListener::bind(cfg.listen_addr).await?;
    tracing::info!(addr = %cfg.listen_addr, "API listening");
    axum::serve(listener, api::router(state))
        .with_graceful_shutdown(shutdown)
        .await?;
    tracing::info!("shutting down");
    Ok(())
}

/// Discovery loop: re-scan on the configured interval. (Manual scans go through
/// the synchronous `POST /scan` endpoint instead.)
async fn scan_loop(
    db: Db,
    cfg: Arc<Config>,
    check_notify: Arc<Notify>,
    fetch_notify: Arc<Notify>,
) {
    let mut ticker = interval(cfg.scan_interval());
    loop {
        ticker.tick().await;
        if let Err(e) = run_scan(&db, &cfg).await {
            tracing::warn!(error = %e, "scan failed");
        }
        // New repos were (possibly) added — refresh their status promptly, and
        // kick off a fetch so 'behind' is populated (also fixes startup
        // ordering: the fetch loop has the repo list only after the first scan).
        check_notify.notify_one();
        fetch_notify.notify_one();
    }
}

/// Discover repos under the configured roots, upsert them, and prune any that
/// disappeared from disk. Shared by the periodic loop and `POST /scan`.
pub async fn run_scan(db: &Db, cfg: &Config) -> Result<()> {
    let roots = cfg.resolved_scan_roots();
    let excludes = cfg.scan_excludes.clone();
    let found = tokio::task::spawn_blocking(move || scan::discover(&roots, &excludes)).await?;

    for path in &found {
        db.upsert_discovered(path)?;
    }
    // Prune repos that have disappeared from disk.
    let mut removed = 0;
    for path in db.list_paths()? {
        if !scan::still_exists(&path) {
            db.delete(&path)?;
            removed += 1;
        }
    }
    tracing::info!(found = found.len(), removed, "scan complete");
    Ok(())
}

/// Status-check loop: recompute every repo's local status.
async fn check_loop(db: Db, cfg: Arc<Config>, check_notify: Arc<Notify>) {
    let mut ticker = interval(cfg.check_interval());
    loop {
        tokio::select! {
            _ = ticker.tick() => {}
            _ = check_notify.notified() => {}
        }
        check_all(&db).await;
    }
}

/// Recompute and persist local status for every tracked repo. Shared by the
/// periodic loop and the synchronous `POST /check` endpoint, so a manual refresh
/// returns only once the on-disk state has actually been re-inspected.
pub async fn check_all(db: &Db) {
    let paths = match db.list_paths() {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!(error = %e, "could not list repos for check");
            return;
        }
    };

    let sem = Arc::new(Semaphore::new(CONCURRENCY));
    let mut set = JoinSet::new();
    for path in paths {
        let permit = sem.clone().acquire_owned().await.unwrap();
        let db = db.clone();
        set.spawn(async move {
            let _permit = permit;
            match tokio::task::spawn_blocking(move || compute_status(&path)).await {
                Ok(stat) => {
                    if let Err(e) = db.save_status(&stat) {
                        tracing::warn!(error = %e, "saving status failed");
                    }
                }
                Err(e) => tracing::warn!(error = %e, "status task panicked"),
            }
        });
    }
    let n = set.len();
    while set.join_next().await.is_some() {}
    tracing::debug!(repos = n, "status check complete");
}

/// Fetch loop: refresh remote-tracking refs so the next check sees fresh
/// `behind` counts. Each fetch is bounded by a timeout.
async fn fetch_loop(
    db: Db,
    cfg: Arc<Config>,
    fetch_notify: Arc<Notify>,
    check_notify: Arc<Notify>,
) {
    let mut ticker = interval(cfg.fetch_interval());
    loop {
        tokio::select! {
            _ = ticker.tick() => {}
            _ = fetch_notify.notified() => {}
        }
        let paths = match db.list_paths() {
            Ok(p) => p,
            Err(e) => {
                tracing::warn!(error = %e, "could not list repos for fetch");
                continue;
            }
        };

        let sem = Arc::new(Semaphore::new(CONCURRENCY));
        let mut set = JoinSet::new();
        for path in paths {
            let permit = sem.clone().acquire_owned().await.unwrap();
            let db = db.clone();
            set.spawn(async move {
                let _permit = permit;
                let p = path.clone();
                let res = timeout(
                    fetch::FETCH_TIMEOUT,
                    tokio::task::spawn_blocking(move || fetch::fetch_repo(&p)),
                )
                .await;
                match res {
                    Ok(Ok(Ok(()))) => {
                        let _ = db.set_last_fetched(&path, now_unix());
                    }
                    Ok(Ok(Err(msg))) => {
                        tracing::debug!(repo = %path.display(), error = %msg, "fetch failed");
                        let _ = db.set_fetch_error(&path, &msg);
                    }
                    Ok(Err(e)) => tracing::warn!(error = %e, "fetch task panicked"),
                    Err(_) => {
                        tracing::debug!(repo = %path.display(), "fetch timed out");
                        let _ = db.set_fetch_error(&path, "fetch timed out");
                    }
                }
            });
        }
        while set.join_next().await.is_some() {}
        // Recompute status now that remote refs may have advanced.
        check_notify.notify_one();
    }
}
