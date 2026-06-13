//! Local git inspection via git2. No network access happens here — everything is
//! read from the on-disk repository and its cached remote-tracking refs.

use crate::model::{Operation, RepoStatus, Upstream};
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
