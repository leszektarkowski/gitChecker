//! Network refresh: shell out to the `git` binary to fetch each repo.
//!
//! We deliberately use the `git` CLI rather than git2's fetch so that existing
//! credentials — SSH agent, keychain, credential helpers — are reused without
//! reimplementing auth.

use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

/// Fetch all remotes for the repo at `path`. Returns `Ok(())` on success, or the
/// captured stderr on failure. Has a short hard timeout so an unreachable or
/// password-prompting remote can't wedge the loop.
pub fn fetch_repo(path: &Path) -> Result<(), String> {
    // Make the fetch fully non-interactive so it can never block on a prompt:
    //   - GIT_TERMINAL_PROMPT=0 disables git's own credential prompts.
    //   - GIT_SSH_COMMAND forces SSH into batch mode: BatchMode=yes disables
    //     password/passphrase prompts, StrictHostKeyChecking=accept-new auto-
    //     trusts a first-seen host key (so a never-before-seen host like
    //     bitbucket.org is added instead of hanging on a yes/no prompt), and
    //     ConnectTimeout caps how long a dead remote can stall us.
    //   - stdin is /dev/null so no child can read from the controlling terminal.
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(["fetch", "--all", "--quiet", "--no-tags"])
        .env("GIT_TERMINAL_PROMPT", "0")
        .env(
            "GIT_SSH_COMMAND",
            "ssh -oBatchMode=yes -oStrictHostKeyChecking=accept-new -oConnectTimeout=10",
        )
        .stdin(Stdio::null())
        .output();

    match output {
        Ok(out) if out.status.success() => Ok(()),
        Ok(out) => {
            let msg = String::from_utf8_lossy(&out.stderr);
            Err(msg.trim().to_string())
        }
        Err(e) => Err(format!("failed to run git: {e}")),
    }
}

/// Upper bound on how long a single fetch may run before we consider it stuck.
/// (Enforced by the caller via `spawn_blocking` + timeout.)
pub const FETCH_TIMEOUT: Duration = Duration::from_secs(30);
