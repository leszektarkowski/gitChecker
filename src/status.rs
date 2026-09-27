//! Local git inspection via git2. No network access happens here — everything is
//! read from the on-disk repository and its cached remote-tracking refs.

use crate::model::{CommitInfo, Operation, RepoDetails, RepoStatus, Upstream};
use git2::{BranchType, ErrorCode, Repository, RepositoryState, Status, StatusOptions};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// Current Unix time in whole seconds.
pub fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Compute the full status of the repository at `path`. Never panics: any error
/// reading the repo is captured in `RepoStatus::error`.
pub fn compute_status(path: &Path) -> RepoStatus {
    let mut status = RepoStatus::new(path.to_path_buf());

    let mut repo = match Repository::open(path) {
        Ok(r) => r,
        Err(e) => {
            status.error = Some(format!("open failed: {}", e.message()));
            return status;
        }
    };

    if let Err(e) = inspect(&mut repo, &mut status) {
        status.error = Some(e.message().to_string());
    }

    status.last_checked = Some(now_unix());
    status
}

/// Fill `status` from `repo`. Returns the first hard git2 error encountered.
fn inspect(repo: &mut Repository, status: &mut RepoStatus) -> Result<(), git2::Error> {
    working_tree(repo, status)?;
    status.operation = map_state(repo.state());
    status.stash_count = count_stash(repo);
    branch_and_upstream(repo, status)?;
    Ok(())
}

/// Set working-tree dirtiness flags from the porcelain status list.
fn working_tree(repo: &Repository, status: &mut RepoStatus) -> Result<(), git2::Error> {
    let mut opts = StatusOptions::new();
    opts.include_untracked(true)
        .include_ignored(false)
        // libgit2's defaults include RECURSE_UNTRACKED_DIRS, which walks every
        // file inside an untracked directory. We only need the boolean "is
        // anything untracked?", so one entry per untracked dir is enough — this
        // keeps a stray build/ or un-ignored node_modules/ from being stat'ed
        // in full on every check.
        .recurse_untracked_dirs(false)
        .renames_head_to_index(true)
        .renames_index_to_workdir(true);

    let staged = Status::INDEX_NEW
        | Status::INDEX_MODIFIED
        | Status::INDEX_DELETED
        | Status::INDEX_RENAMED
        | Status::INDEX_TYPECHANGE;
    let unstaged = Status::WT_MODIFIED
        | Status::WT_DELETED
        | Status::WT_TYPECHANGE
        | Status::WT_RENAMED;

    for entry in repo.statuses(Some(&mut opts))?.iter() {
        let s = entry.status();
        if s.intersects(staged) {
            status.has_staged = true;
        }
        if s.intersects(unstaged) {
            status.has_unstaged = true;
        }
        if s.contains(Status::WT_NEW) {
            status.has_untracked = true;
        }
    }
    Ok(())
}

/// Resolve the current branch and its ahead/behind relationship to upstream.
fn branch_and_upstream(
    repo: &Repository,
    status: &mut RepoStatus,
) -> Result<(), git2::Error> {
    status.detached_head = repo.head_detached().unwrap_or(false);

    let head = match repo.head() {
        Ok(h) => h,
        // Unborn branch: a fresh repo with no commits yet. Not an error for us.
        Err(e) if e.code() == ErrorCode::UnbornBranch => return Ok(()),
        Err(e) => return Err(e),
    };

    if status.detached_head {
        return Ok(());
    }

    let Some(branch_name) = head.shorthand().ok().map(str::to_owned) else {
        return Ok(());
    };
    status.branch = Some(branch_name.clone());

    let local = repo.find_branch(&branch_name, BranchType::Local)?;
    let upstream = match local.upstream() {
        Ok(u) => u,
        // No upstream configured for this branch.
        Err(e) if e.code() == ErrorCode::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };

    let upstream_name = upstream
        .name()?
        .map(str::to_owned)
        .unwrap_or_else(|| "?".into());

    let (ahead, behind) = match (head.target(), upstream.get().target()) {
        (Some(local_oid), Some(up_oid)) => repo.graph_ahead_behind(local_oid, up_oid)?,
        _ => (0, 0),
    };

    status.upstream = Upstream::Tracking {
        name: upstream_name,
        ahead,
        behind,
    };
    Ok(())
}

/// Count stash entries. Errors are treated as "no stash" rather than failing the
/// whole status computation.
fn count_stash(repo: &mut Repository) -> usize {
    let mut count = 0;
    let _ = repo.stash_foreach(|_, _, _| {
        count += 1;
        true
    });
    count
}

/// Map git2's repository state to our `Operation`.
fn map_state(state: RepositoryState) -> Operation {
    match state {
        RepositoryState::Clean => Operation::Clean,
        RepositoryState::Merge => Operation::Merge,
        RepositoryState::Revert | RepositoryState::RevertSequence => Operation::Revert,
        RepositoryState::CherryPick | RepositoryState::CherryPickSequence => {
            Operation::CherryPick
        }
        RepositoryState::Bisect => Operation::Bisect,
        RepositoryState::Rebase
        | RepositoryState::RebaseInteractive
        | RepositoryState::RebaseMerge => Operation::Rebase,
        RepositoryState::ApplyMailbox | RepositoryState::ApplyMailboxOrRebase => {
            Operation::ApplyMailbox
        }
    }
}

/// Detailed, on-demand view of one repo for the hover card: which files are
/// staged / modified / untracked / conflicted, the HEAD commit, the remote URL
/// and stash messages. Never panics; errors land in `RepoDetails::error`.
pub fn compute_details(path: &Path) -> RepoDetails {
    let mut details = RepoDetails::new(path.to_path_buf());
    let mut repo = match Repository::open(path) {
        Ok(r) => r,
        Err(e) => {
            details.error = Some(format!("open failed: {}", e.message()));
            return details;
        }
    };
    if let Err(e) = fill_details(&mut repo, &mut details) {
        details.error = Some(e.message().to_string());
    }
    details
}

fn fill_details(repo: &mut Repository, d: &mut RepoDetails) -> Result<(), git2::Error> {
    {
        let mut opts = StatusOptions::new();
        opts.include_untracked(true)
            .include_ignored(false)
            .recurse_untracked_dirs(false) // an untracked dir is listed once, as "dir/"
            .renames_head_to_index(true)
            .renames_index_to_workdir(true);
        let statuses = repo.statuses(Some(&mut opts))?;
        for entry in statuses.iter() {
            let s = entry.status();
            let path = entry.path().unwrap_or("?").to_string();
            if s.contains(Status::CONFLICTED) {
                d.conflicted.push(path, "conflicted");
                continue;
            }
            if let Some(kind) = index_kind(s) {
                let label = match entry.head_to_index() {
                    Some(delta) if s.contains(Status::INDEX_RENAMED) => rename_label(&delta),
                    _ => None,
                };
                d.staged.push(label.unwrap_or_else(|| path.clone()), kind);
            }
            if let Some(kind) = worktree_kind(s) {
                let label = match entry.index_to_workdir() {
                    Some(delta) if s.contains(Status::WT_RENAMED) => rename_label(&delta),
                    _ => None,
                };
                d.unstaged.push(label.unwrap_or_else(|| path.clone()), kind);
            }
            if s.contains(Status::WT_NEW) {
                d.untracked.push(path, "untracked");
            }
        }
    }

    if let Ok(commit) = repo.head().and_then(|h| h.peel_to_commit()) {
        d.last_commit = Some(CommitInfo {
            summary: commit.summary().ok().flatten().unwrap_or("").to_string(),
            author: commit.author().name().unwrap_or("").to_string(),
            time: commit.time().seconds(),
        });
    }

    // Prefer `origin`; otherwise the first configured remote.
    d.remote_url = repo
        .find_remote("origin")
        .ok()
        .and_then(|r| r.url().ok().map(str::to_owned))
        .or_else(|| {
            let names = repo.remotes().ok()?;
            let first = names.iter().filter_map(|n| n.ok().flatten()).next()?.to_owned();
            repo.find_remote(&first).ok()?.url().ok().map(str::to_owned)
        });

    let mut stashes = Vec::new();
    let _ = repo.stash_foreach(|_, message, _| {
        stashes.push(message.to_string());
        true
    });
    d.stashes = stashes;
    Ok(())
}

fn index_kind(s: Status) -> Option<&'static str> {
    if s.contains(Status::INDEX_NEW) {
        Some("added")
    } else if s.contains(Status::INDEX_MODIFIED) {
        Some("modified")
    } else if s.contains(Status::INDEX_DELETED) {
        Some("deleted")
    } else if s.contains(Status::INDEX_RENAMED) {
        Some("renamed")
    } else if s.contains(Status::INDEX_TYPECHANGE) {
        Some("typechange")
    } else {
        None
    }
}

fn worktree_kind(s: Status) -> Option<&'static str> {
    if s.contains(Status::WT_MODIFIED) {
        Some("modified")
    } else if s.contains(Status::WT_DELETED) {
        Some("deleted")
    } else if s.contains(Status::WT_RENAMED) {
        Some("renamed")
    } else if s.contains(Status::WT_TYPECHANGE) {
        Some("typechange")
    } else {
        None
    }
}

/// "old → new" for a rename.
fn rename_label(delta: &git2::DiffDelta<'_>) -> Option<String> {
    let old = delta.old_file().path()?.display().to_string();
    let new = delta.new_file().path()?.display().to_string();
    Some(format!("{old} → {new}"))
}
