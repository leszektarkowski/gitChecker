//! SQLite persistence. One row per repository, keyed by its stable id.
//!
//! The computed status is stored as JSON, but only **rewritten when it actually
//! changes**: the volatile "when did we last look" timestamp is kept in memory
//! rather than on disk, so a no-change check costs zero disk I/O (previously
//! every check was an fsync'd write because the timestamp always differed).
//! `last_fetched` / fetch backoff state live in their own columns so the fetch
//! loop can update them without touching the status blob.

use crate::model::{repo_id, RepoStatus};
use crate::status::now_unix;
use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// Per-repo in-memory bookkeeping for the write-on-change path.
struct CheckCache {
    /// When this process last inspected the repo. Not persisted: on restart it
    /// is `None` until the startup check runs (seconds), which is honest.
    last_checked: i64,
    /// The status JSON most recently confirmed to be what's on disk.
    json: String,
}

#[derive(Clone)]
pub struct Db {
    conn: Arc<Mutex<Connection>>,
    cache: Arc<Mutex<HashMap<String, CheckCache>>>,
}

impl Db {
    /// Open (creating if needed) the database at `path` and ensure the schema.
    pub fn open(path: &Path) -> Result<Db> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating data dir {}", parent.display()))?;
        }
        let conn = Connection::open(path)
            .with_context(|| format!("opening database {}", path.display()))?;
        // WAL + NORMAL: writes append to the WAL and fsync only at checkpoints,
        // far fewer disk syncs than the default rollback journal + FULL.
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS repos (
                 id               TEXT PRIMARY KEY,
                 path             TEXT NOT NULL UNIQUE,
                 status_json      TEXT,
                 last_fetched     INTEGER,
                 last_fetch_error TEXT,
                 fetch_failures   INTEGER NOT NULL DEFAULT 0,
                 next_fetch_after INTEGER,
                 discovered_at    INTEGER NOT NULL
             );",
        )?;
        // Migrate databases created before these columns existed. Each ALTER
        // errors with "duplicate column" once applied, which we ignore.
        let _ = conn.execute("ALTER TABLE repos ADD COLUMN last_fetch_error TEXT", []);
        let _ = conn.execute(
            "ALTER TABLE repos ADD COLUMN fetch_failures INTEGER NOT NULL DEFAULT 0",
            [],
        );
        let _ = conn.execute("ALTER TABLE repos ADD COLUMN next_fetch_after INTEGER", []);
        Ok(Db {
            conn: Arc::new(Mutex::new(conn)),
            cache: Arc::new(Mutex::new(HashMap::new())),
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Connection> {
        // Poisoning only happens if a holder panicked mid-write; recover the
        // guard rather than propagating, since our writes are simple.
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn cache(&self) -> std::sync::MutexGuard<'_, HashMap<String, CheckCache>> {
        self.cache.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Record a freshly discovered repo. No-op if already known.
    pub fn upsert_discovered(&self, path: &Path) -> Result<()> {
        let id = repo_id(path);
        self.lock().execute(
            "INSERT INTO repos (id, path, status_json, last_fetched, discovered_at)
             VALUES (?1, ?2, NULL, NULL, ?3)
             ON CONFLICT(id) DO NOTHING",
            params![id, path.to_string_lossy(), now_unix()],
        )?;
        Ok(())
    }

    /// Remove a repo that no longer exists on disk.
    pub fn delete(&self, path: &Path) -> Result<()> {
        let id = repo_id(path);
        self.lock()
            .execute("DELETE FROM repos WHERE id = ?1", params![id])?;
        // Drop the cache entry so a re-discovered repo can't be mistaken for
        // "unchanged" against a row that no longer holds its status.
        self.cache().remove(&id);
        Ok(())
    }

    /// Persist a freshly computed status — but only hit the disk if it differs
    /// from what's already stored. The check timestamp is kept in memory.
    pub fn save_status(&self, status: &RepoStatus) -> Result<()> {
        let ts = status.last_checked.unwrap_or_else(now_unix);

        // Serialize without the fields that live elsewhere (in memory or in
        // their own columns) so the blob is stable and comparable.
        let mut stable = status.clone();
        stable.last_checked = None;
        stable.last_fetched = None;
        stable.last_fetch_error = None;
        let json = serde_json::to_string(&stable)?;

        // What's on disk: from cache once known, else one read (no nested locks).
        let cached = self.cache().get(&status.id).map(|c| c.json.clone());
        let on_disk = match cached {
            Some(j) => Some(j),
            None => self.stored_json(&status.id)?,
        };

        if on_disk.as_deref() != Some(json.as_str()) {
            self.lock().execute(
                "UPDATE repos SET status_json = ?2 WHERE id = ?1",
                params![status.id, json],
            )?;
        }
        self.cache().insert(
            status.id.clone(),
            CheckCache {
                last_checked: ts,
                json,
            },
        );
        Ok(())
    }

    fn stored_json(&self, id: &str) -> Result<Option<String>> {
        let v = self
            .lock()
            .query_row(
                "SELECT status_json FROM repos WHERE id = ?1",
                params![id],
                |r| r.get::<_, Option<String>>(0),
            )
            .optional()?;
        Ok(v.flatten())
    }

    /// Record a successful fetch for `path`: stamp the time, clear any error,
    /// and reset the failure backoff.
    pub fn set_last_fetched(&self, path: &Path, ts: i64) -> Result<()> {
        self.lock().execute(
            "UPDATE repos
             SET last_fetched = ?2, last_fetch_error = NULL,
                 fetch_failures = 0, next_fetch_after = NULL
             WHERE id = ?1",
            params![repo_id(path), ts],
        )?;
        Ok(())
    }

    /// Record a failed fetch and push the next attempt out with exponential
    /// backoff: wait `base * 2^failures` seconds (capped at `cap`) before trying
    /// again. A single UPDATE, using the pre-update `fetch_failures` value.
    pub fn record_fetch_failure(
        &self,
        path: &Path,
        msg: &str,
        base_secs: i64,
        cap_secs: i64,
    ) -> Result<()> {
        self.lock().execute(
            "UPDATE repos
             SET last_fetch_error = ?2,
                 next_fetch_after = ?3 + min(?4 << min(fetch_failures, 10), ?5),
                 fetch_failures   = fetch_failures + 1
             WHERE id = ?1",
            params![repo_id(path), msg, now_unix(), base_secs, cap_secs],
        )?;
        Ok(())
    }

    /// Paths of all known repos (drives the check and scan loops).
    pub fn list_paths(&self) -> Result<Vec<PathBuf>> {
        let conn = self.lock();
        let mut stmt = conn.prepare("SELECT path FROM repos ORDER BY path")?;
        let rows = stmt
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows.into_iter().map(PathBuf::from).collect())
    }

    /// Repos whose last fetch failed, regardless of backoff (manual retry).
    pub fn list_failed_fetches(&self) -> Result<Vec<PathBuf>> {
        let conn = self.lock();
        let mut stmt = conn.prepare(
            "SELECT path FROM repos WHERE last_fetch_error IS NOT NULL ORDER BY path",
        )?;
        let rows = stmt
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows.into_iter().map(PathBuf::from).collect())
    }

    /// Repos due for a fetch: not currently backing off after failures.
    pub fn list_fetch_candidates(&self, now: i64) -> Result<Vec<PathBuf>> {
        let conn = self.lock();
        let mut stmt = conn.prepare(
            "SELECT path FROM repos
             WHERE next_fetch_after IS NULL OR next_fetch_after <= ?1
             ORDER BY path",
        )?;
        let rows = stmt
            .query_map(params![now], |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows.into_iter().map(PathBuf::from).collect())
    }

    /// All repo statuses for the API, with the column-backed and in-memory
    /// fields merged in.
    pub fn list_statuses(&self) -> Result<Vec<RepoStatus>> {
        let rows = {
            let conn = self.lock();
            let mut stmt = conn.prepare(
                "SELECT id, path, status_json, last_fetched, last_fetch_error
                 FROM repos ORDER BY path",
            )?;
            let rows = stmt
                .query_map([], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, Option<String>>(2)?,
                        r.get::<_, Option<i64>>(3)?,
                        r.get::<_, Option<String>>(4)?,
                    ))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            rows
        };
        let cache = self.cache();
        Ok(rows
            .into_iter()
            .map(|(id, path, json, fetched, err)| {
                let checked = cache.get(&id).map(|c| c.last_checked);
                hydrate(path, json, fetched, err, checked)
            })
            .collect())
    }

    /// A single repo status by id.
    pub fn get_status(&self, id: &str) -> Result<Option<RepoStatus>> {
        let row = self
            .lock()
            .query_row(
                "SELECT path, status_json, last_fetched, last_fetch_error
                 FROM repos WHERE id = ?1",
                params![id],
                |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, Option<String>>(1)?,
                        r.get::<_, Option<i64>>(2)?,
                        r.get::<_, Option<String>>(3)?,
                    ))
                },
            )
            .optional()?;
        let checked = self.cache().get(id).map(|c| c.last_checked);
        Ok(row.map(|(path, json, fetched, err)| hydrate(path, json, fetched, err, checked)))
    }
}

/// Build a `RepoStatus` from stored columns, falling back to a blank status when
/// the repo has been discovered but never checked.
fn hydrate(
    path: String,
    json: Option<String>,
    fetched: Option<i64>,
    fetch_error: Option<String>,
    last_checked: Option<i64>,
) -> RepoStatus {
    let path = PathBuf::from(path);
    let mut status = json
        .and_then(|j| serde_json::from_str::<RepoStatus>(&j).ok())
        .unwrap_or_else(|| RepoStatus::new(path.clone()));
    status.last_fetched = fetched;
    status.last_fetch_error = fetch_error;
    status.last_checked = last_checked;
    status
}
