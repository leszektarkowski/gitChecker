//! SQLite persistence. One row per repository, keyed by its stable id.
//!
//! The full computed status is stored as JSON for flexibility, while
//! `last_fetched` lives in its own column so the fetch loop can update it
//! without rewriting (or racing) the status blob.

use crate::model::{repo_id, RepoStatus};
use crate::status::now_unix;
use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

#[derive(Clone)]
pub struct Db {
    conn: Arc<Mutex<Connection>>,
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
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS repos (
                 id               TEXT PRIMARY KEY,
                 path             TEXT NOT NULL UNIQUE,
                 status_json      TEXT,
                 last_fetched     INTEGER,
                 last_fetch_error TEXT,
                 discovered_at    INTEGER NOT NULL
             );",
        )?;
        // Migrate databases created before last_fetch_error existed. The ALTER
        // errors with "duplicate column" once applied, which we ignore.
        let _ = conn.execute("ALTER TABLE repos ADD COLUMN last_fetch_error TEXT", []);
        Ok(Db {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Connection> {
        // Poisoning only happens if a holder panicked mid-write; recover the
        // guard rather than propagating, since our writes are simple.
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
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
        self.lock()
            .execute("DELETE FROM repos WHERE id = ?1", params![repo_id(path)])?;
        Ok(())
    }

    /// Persist a freshly computed status, preserving the stored `last_fetched`.
    pub fn save_status(&self, status: &RepoStatus) -> Result<()> {
        let json = serde_json::to_string(status)?;
        self.lock().execute(
            "UPDATE repos SET status_json = ?2 WHERE id = ?1",
            params![status.id, json],
        )?;
        Ok(())
    }

    /// Record a successful fetch for `path`, clearing any prior fetch error.
    pub fn set_last_fetched(&self, path: &Path, ts: i64) -> Result<()> {
        self.lock().execute(
            "UPDATE repos SET last_fetched = ?2, last_fetch_error = NULL WHERE id = ?1",
            params![repo_id(path), ts],
        )?;
        Ok(())
    }

    /// Record that the most recent fetch for `path` failed.
    pub fn set_fetch_error(&self, path: &Path, msg: &str) -> Result<()> {
        self.lock().execute(
            "UPDATE repos SET last_fetch_error = ?2 WHERE id = ?1",
            params![repo_id(path), msg],
        )?;
        Ok(())
    }

    /// Paths of all known repos (drives the check and fetch loops).
    pub fn list_paths(&self) -> Result<Vec<PathBuf>> {
        let conn = self.lock();
        let mut stmt = conn.prepare("SELECT path FROM repos ORDER BY path")?;
        let rows = stmt
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows.into_iter().map(PathBuf::from).collect())
    }

    /// All repo statuses for the API, with `last_fetched` joined from its column.
    pub fn list_statuses(&self) -> Result<Vec<RepoStatus>> {
        let conn = self.lock();
        let mut stmt = conn.prepare(
            "SELECT path, status_json, last_fetched, last_fetch_error FROM repos ORDER BY path",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, Option<String>>(1)?,
                    r.get::<_, Option<i64>>(2)?,
                    r.get::<_, Option<String>>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        Ok(rows
            .into_iter()
            .map(|(path, json, fetched, err)| hydrate(path, json, fetched, err))
            .collect())
    }

    /// A single repo status by id.
    pub fn get_status(&self, id: &str) -> Result<Option<RepoStatus>> {
        let conn = self.lock();
        let row = conn
            .query_row(
                "SELECT path, status_json, last_fetched, last_fetch_error FROM repos WHERE id = ?1",
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
        Ok(row.map(|(path, json, fetched, err)| hydrate(path, json, fetched, err)))
    }
}

/// Build a `RepoStatus` from stored columns, falling back to a blank status when
/// the repo has been discovered but never checked.
fn hydrate(
    path: String,
    json: Option<String>,
    fetched: Option<i64>,
    fetch_error: Option<String>,
) -> RepoStatus {
    let path = PathBuf::from(path);
    let mut status = json
        .and_then(|j| serde_json::from_str::<RepoStatus>(&j).ok())
        .unwrap_or_else(|| RepoStatus::new(path.clone()));
    status.last_fetched = fetched;
    status.last_fetch_error = fetch_error;
    status
}
