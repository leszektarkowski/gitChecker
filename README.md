# gitchecker

A small local service that periodically discovers git repositories on your
machine and reports their status over an HTTP API, so you never lose track of
work that's uncommitted, unpushed, or behind origin.

It runs two cadences:

- **Discovery scan** (default: daily) — walk the configured roots for `.git`
  folders.
- **Status check** (default: every 5 min) — recompute each repo's local status.

A separate, slower **fetch** loop (default: every 30 min) runs `git fetch` so the
`behind origin` count stays fresh without hammering remotes.

## Status model

Status is a *set of flags*, not a single state — a repo can be dirty, ahead, and
behind all at once. Per repo we report:

| Field | Meaning |
|-------|---------|
| `branch` / `detached_head` | current branch, or detached HEAD |
| `has_staged` / `has_unstaged` / `has_untracked` | working-tree dirtiness |
| `stash_count` | number of stash entries |
| `operation` | in-progress merge/rebase/cherry-pick/etc. (conflict state) |
| `upstream` | `none`, or `tracking { name, ahead, behind }` |
| `error` | set if the repo couldn't be read |
| `last_checked` / `last_fetched` | Unix timestamps |
| `last_fetch_error` | error from the last fetch (auth/network); cleared on success — when set, `behind` may be stale |

> `behind` is only as fresh as the last fetch. The fetch loop refreshes it on its
> own cadence; before the first fetch it reflects cached remote-tracking refs.

## Design notes

- **Local inspection uses [git2-rs]; fetching shells out to the `git` binary.**
  git2 handles all local reads (working tree, ahead/behind, branches, stash) with
  no credentials. The `git fetch` step reuses your existing SSH keys / keychain /
  credential helpers — `GIT_TERMINAL_PROMPT=0` makes it fail fast instead of
  blocking on a password prompt, and each fetch has a 30s timeout.
- State is persisted to SQLite, so status survives restarts (no full re-scan
  needed to answer the first request).

## Build & run

```sh
cargo build --release
./target/release/gitchecker
```

On first run it writes a default config and prints its path. Defaults
(Linux/macOS):

- Config: `~/.config/gitchecker/config.toml` (macOS: `~/Library/Application Support/gitchecker/config.toml`)
- Database: platform data dir, `gitchecker/state.db`

### Configuration (`config.toml`)

```toml
scan_roots = ["~/code"]            # directories to scan for .git folders
scan_excludes = ["node_modules", "target", "vendor", ".cache"]
scan_interval_secs = 86400         # 1 day
check_interval_secs = 300          # 5 min
fetch_interval_secs = 1800         # 30 min
fetch_enabled = true               # set false to never touch the network
listen_addr = "127.0.0.1:7878"
```

`~` in `scan_roots` is expanded to your home directory.

## HTTP API

| Method & path | Description |
|---------------|-------------|
| `GET /healthz` | liveness check (`ok`) |
| `GET /repos` | all tracked repos with current status (JSON array) |
| `GET /repos/{id}` | one repo by id (`id` is a stable hash of its path) |
| `GET /summary` | aggregate counts across all repos (cheap; for badges/prompts) |
| `POST /scan` | trigger a discovery scan now (async, returns `202`) |
| `POST /check` | re-inspect all repos **synchronously**; returns `200` once done, so a follow-up `GET /repos` reflects current on-disk state |

```sh
curl -s localhost:7878/repos | jq
curl -s localhost:7878/summary | jq
```

`GET /summary` returns counts a thin client (menu bar badge, shell prompt) can
poll without fetching the full list:

```json
{
  "total": 18, "attention": 11, "uncommitted": 11,
  "ahead": 1, "behind": 2, "stashed": 0,
  "in_progress": 0, "fetch_errors": 2, "read_errors": 0
}
```

`attention` is the headline count — repos with local work at risk (dirty tree,
stash, unpushed commits, or an interrupted operation).

## Clients

| Client | Location | Status |
|--------|----------|--------|
| macOS menu bar app | [`clients/menubar`](clients/menubar) | ✅ working (`swift run`) |
| Windows system tray app | [`clients/wingitchecker`](clients/wingitchecker) | ✅ working (`dotnet run`) |

Both clients show the attention count and a click-through list of repos; clicking
one opens a terminal at its folder. See the
[menu bar README](clients/menubar/README.md) and the
[system tray README](clients/wingitchecker/README.md).

## Install (macOS)

One command builds everything and sets it up:

```sh
dist/install.sh
```

This:

- builds the release server and installs it to `~/.local/bin/gitchecker`;
- loads it as a **launchd LaunchAgent** (`com.user.gitchecker`) that starts at
  login and restarts on crash (`RunAtLoad` + `KeepAlive`), independent of the GUI;
- builds and installs the menu bar app to `/Applications/GitCheckerBar.app` and
  launches it.

To have the menu bar app start at login too, open its menu and flip
**Start at login** (registered via `SMAppService`).

Logs go to `~/Library/Logs/gitchecker.log`. Manage the service directly with:

```sh
launchctl print    gui/$(id -u)/com.user.gitchecker   # status
launchctl kickstart -k gui/$(id -u)/com.user.gitchecker # restart
```

> The LaunchAgent sets an explicit `PATH` (`/opt/homebrew/bin:…`) so the server
> can find `git` when it fetches — launchd's default `PATH` wouldn't include
> Homebrew.

Uninstall (leaves your config/database):

```sh
dist/uninstall.sh
```

## Install (Windows)

The server runs at logon via a per-user **Scheduled Task** — the direct analog of
the macOS LaunchAgent. Crucially it runs as **you**, not as a system account: git
refuses to operate on a repository owned by a different user (the "dubious
ownership" protection), so a LocalSystem service can't read your repos at all and
has none of your git credentials. Running as you avoids both problems.

From a normal PowerShell (it self-elevates via a UAC prompt — elevation is only
needed to register the task and to clear out any previous service install):

```powershell
dist\windows\install.ps1
```

This:

- builds the release server (warns if the Rust toolchain is missing);
- copies it to `%ProgramData%\gitchecker\bin\gitchecker.exe`;
- removes any leftover LocalSystem `gitchecker` service from older installs;
- registers a Scheduled Task that starts the server **at logon, hidden, as you**,
  restarting on crash, then starts it and waits for `http://127.0.0.1:7878`.

Because it runs as you, the config lives at the normal per-user path
`%APPDATA%\gitchecker\config\config.toml` and scans `~\code` by default. Re-run
the script any time to upgrade to a fresh build. Manage it with:

```powershell
Get-ScheduledTaskInfo gitchecker   # status / last run
Stop-ScheduledTask     gitchecker
Start-ScheduledTask    gitchecker
```

Build-only helpers (no admin needed):

```powershell
dist\windows\build-server.ps1            # just build the server exe
clients\wingitchecker\build.ps1          # build/publish the tray client
```

Uninstall (leaves your config/database; add `-Purge` to remove them too):

```powershell
dist\windows\uninstall.ps1
```

The **tray client** (`clients\wingitchecker`) is a separate, user-level app — see
its [README](clients/wingitchecker/README.md). Build it with `build.ps1` and drop
a shortcut to the published exe into `shell:startup` to launch it at login.

## License

[MIT](LICENSE) — do whatever you like, just keep the copyright notice.

[git2-rs]: https://github.com/rust-lang/git2-rs
