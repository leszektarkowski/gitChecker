//! Discovery: walk the configured roots looking for `.git` directories.
//!
//! When a `.git` entry is found, its parent is recorded as a repository and we
//! stop descending into that tree — so we don't walk a repo's own internals or
//! recurse into submodules.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

/// Find all repository working directories under `roots`, skipping any directory
/// whose name appears in `excludes`.
pub fn discover(roots: &[PathBuf], excludes: &[String]) -> Vec<PathBuf> {
    let exclude: HashSet<&str> = excludes.iter().map(String::as_str).collect();
    let mut repos = Vec::new();

    for root in roots {
        if !root.exists() {
            tracing::warn!(root = %root.display(), "scan root does not exist, skipping");
            continue;
        }

        let mut it = WalkDir::new(root).follow_links(false).into_iter();
        while let Some(entry) = it.next() {
            let entry = match entry {
                Ok(e) => e,
                Err(err) => {
                    tracing::debug!(%err, "skipping unreadable entry");
                    continue;
                }
            };

            if !entry.file_type().is_dir() {
                continue;
            }

            let name = entry.file_name().to_string_lossy();

            // Found a repo: record parent, and don't descend into `.git`.
            if name == ".git" {
                if let Some(parent) = entry.path().parent() {
                    repos.push(parent.to_path_buf());
                }
                it.skip_current_dir();
                continue;
            }

            // Prune excluded directories.
            if exclude.contains(name.as_ref()) {
                it.skip_current_dir();
            }
        }
    }

    repos.sort();
    repos.dedup();
    repos
}

/// Whether `path` still looks like a git repository (used to prune deleted ones).
pub fn still_exists(path: &Path) -> bool {
    path.join(".git").exists()
}
