//! Data types describing the status of a tracked git repository.
//!
//! Status is modelled as a set of independent dimensions rather than a single
//! enum, because a repository can be dirty AND ahead AND behind all at once.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// A stable identifier for a repo, derived from its absolute path. Used in API
/// routes so clients can address a single repo without URL-encoding a path.
pub fn repo_id(path: &Path) -> String {
    // FNV-1a over the path bytes — stable across runs, short, no extra deps.
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in path.to_string_lossy().as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

/// Which long-running git operation (if any) is mid-flight, leaving the repo in
/// a conflicted / partially-applied state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Operation {
    Clean,
    Merge,
    Revert,
    CherryPick,
    Bisect,
    Rebase,
    ApplyMailbox,
}

/// The sync relationship between the checked-out branch and its upstream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Upstream {
    /// Branch has no configured upstream, or the repo has no remote at all.
    None,
    /// We know the upstream and how far ahead/behind we are. `behind` is only
    /// fresh after a fetch; before the first fetch it reflects cached refs.
    Tracking {
        name: String,
        ahead: usize,
        behind: usize,
    },
}

/// Full computed status of one repository at a point in time.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepoStatus {
    /// Stable id derived from `path`.
    pub id: String,
    pub path: PathBuf,

    /// Current branch name, or `None` when in detached HEAD.
    pub branch: Option<String>,
    pub detached_head: bool,

    /// Working-tree dirtiness.
    pub has_staged: bool,
    pub has_unstaged: bool,
    pub has_untracked: bool,

    pub stash_count: usize,
    pub operation: Operation,
    pub upstream: Upstream,

    /// If the repo could not be read (corrupt, permission denied, gone), the
    /// reason. When set, the boolean/enum fields above are best-effort defaults.
    pub error: Option<String>,

    /// Unix seconds of the last successful local status check.
    pub last_checked: Option<i64>,
    /// Unix seconds of the last successful `git fetch`.
    pub last_fetched: Option<i64>,
    /// Error from the most recent fetch attempt, if it failed (e.g. auth or
    /// network). Cleared on the next successful fetch. When set, `behind` may be
    /// stale.
    pub last_fetch_error: Option<String>,
}

impl RepoStatus {
    /// A blank status for a freshly discovered path, before its first check.
    pub fn new(path: PathBuf) -> Self {
        RepoStatus {
            id: repo_id(&path),
            path,
            branch: None,
            detached_head: false,
            has_staged: false,
            has_unstaged: false,
            has_untracked: false,
            stash_count: 0,
            operation: Operation::Clean,
            upstream: Upstream::None,
            error: None,
            last_checked: None,
            last_fetched: None,
            last_fetch_error: None,
        }
    }

    /// Whether there is any local work the user might lose: dirty tree, stashes,
    /// unpushed commits, or an interrupted operation. This is the "needs
    /// attention" predicate surfaced by `Summary`.
    pub fn is_dirty(&self) -> bool {
        self.has_staged
            || self.has_unstaged
            || self.has_untracked
            || self.stash_count > 0
            || self.operation != Operation::Clean
            || matches!(self.upstream, Upstream::Tracking { ahead, .. } if ahead > 0)
    }
}

/// Aggregate counts across all tracked repos — the cheap view thin clients
/// (menu bar badge, prompt segment) poll instead of the full list.
#[derive(Debug, Clone, Default, Serialize)]
pub struct Summary {
    /// Total repos tracked.
    pub total: usize,
    /// Repos with local work at risk (`is_dirty`): the headline badge count.
    pub attention: usize,
    /// Repos with working-tree changes (staged / unstaged / untracked).
    pub uncommitted: usize,
    /// Repos with unpushed commits.
    pub ahead: usize,
    /// Repos behind their upstream (as of the last fetch).
    pub behind: usize,
    /// Repos with stash entries.
    pub stashed: usize,
    /// Repos mid-operation (merge / rebase / cherry-pick / etc.).
    pub in_progress: usize,
    /// Repos whose last fetch failed (so `behind` may be stale).
    pub fetch_errors: usize,
    /// Repos that could not be read at all.
    pub read_errors: usize,
}

impl Summary {
    pub fn from_statuses(repos: &[RepoStatus]) -> Self {
        let mut s = Summary {
            total: repos.len(),
            ..Default::default()
        };
        for r in repos {
            if r.is_dirty() {
                s.attention += 1;
            }
            if r.has_staged || r.has_unstaged || r.has_untracked {
                s.uncommitted += 1;
            }
            if let Upstream::Tracking { ahead, behind, .. } = &r.upstream {
                if *ahead > 0 {
                    s.ahead += 1;
                }
                if *behind > 0 {
                    s.behind += 1;
                }
            }
            if r.stash_count > 0 {
                s.stashed += 1;
            }
            if r.operation != Operation::Clean {
                s.in_progress += 1;
            }
            if r.last_fetch_error.is_some() {
                s.fetch_errors += 1;
            }
            if r.error.is_some() {
                s.read_errors += 1;
            }
        }
        s
    }
}
