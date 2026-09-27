# GitCheckerBar — macOS menu bar client

A SwiftUI menu bar app for the gitchecker service. Shows the count of repos that
need attention and lets you jump straight into any of them.

## Requirements

- macOS 14+ (SwiftUI + the Observation framework, hosted in an AppKit popover)
- The gitchecker service running locally (default `http://127.0.0.1:7878`)

## Run

For development:

```sh
cd clients/menubar
swift run            # builds and launches; lives in the menu bar (no Dock icon)
```

To build a proper installable `.app` (needed for the login item):

```sh
clients/menubar/package-app.sh   # -> clients/menubar/build/GitCheckerBar.app
```

This wraps the SPM binary in a bundle with `LSUIElement` (menu-bar agent, no Dock
icon) and ad-hoc code-signs it. `dist/install.sh` runs this and copies the app to
`/Applications`. (The whole thing is usually installed via `dist/install.sh` from
the repo root — see the top-level README.)

The menu bar item shows:

- a ⚠ icon with the **attention count** when repos need it, or a ✓ when all clean;
- a click-through panel listing repos with compact badges:
  `↑N` ahead · `↓N` behind · `●` working-tree changes · `⚑N` stashes ·
  `detached` · `⚠` fetch failed · `✓` clean.

**Hover a repo** for a detail card. What the app already knows appears at
once (branch → upstream, commits to push/pull, working-tree state, stashes, when
it was last fetched, and the full fetch error if any). It then asks the server
for `GET /repos/{id}/details` — a scan of just that repo — and fills in the last
commit, the remote URL, the changed files `git status`-style (`M`/`A`/`D`/`R`/`?`
grouped as Staged / Not staged / Untracked / Conflicted) and stash messages. The
card only opens after a short rest on a row, and details are cached for 10 s, so
sweeping the pointer across the list costs nothing.

A switch in the panel header chooses what's listed: **Issues** (only repos that
need attention — the default) or **All** (every tracked repo, handy as a quick
launcher). The choice is remembered across launches. Long lists scroll.

**Clicking a repo runs the configured `open_command`** with `{path}` set to the
repo's folder (from the server config; defaults to opening Terminal). Set it to
e.g. `smerge {path}` for Sublime Merge — see the top-level README.

**Polling is battery-conscious.** The background poll only reads cached state —
it never triggers a server-side git re-check. When the panel is closed it just
refreshes the badge (`GET /summary`) every 60s; when open it also pulls the list
every 30s. A full re-check (`POST /check`) happens only on panel-open, the
Refresh button, or the server's own 5-minute timer — so an idle, closed menu bar
costs essentially nothing.

The footer has:

- **Refresh** — re-check the status of *known* repos (picks up a repo you just
  cleaned or changed). Backed by the synchronous `POST /check`.
- **Rescan** — re-discover repo folders under the configured roots: finds repos
  added since the last scan and prunes ones that are gone. Backed by the
  synchronous `POST /scan`. Shows "scanning…" while it runs.
- **Start at login** — a checkbox that registers/unregisters the app as a login
  item via `SMAppService` (only effective when run as the installed `.app`, not
  via `swift run`).
- **Configure…** — opens the server config
  (`~/Library/Application Support/gitchecker/config.toml`) in the default text
  editor.
- **Restart** — restarts the service so a config edit takes effect (the server
  reads its config only at startup). It verifies the service comes back up via
  `/healthz`; if it doesn't — usually a malformed config — it warns you to check
  the file and the log instead of silently crash-looping.

Only one copy runs at a time, however it's launched (Finder, `open -n`, the
login item, the raw binary, a dev build) — launching it again just opens the
running copy's panel. To run a dev build (`swift run`), quit the installed app
first.

If the service isn't running it shows "service not running" with a **Start**
button that runs `launchctl kickstart` on the LaunchAgent.

## Architecture

| File | Role |
|------|------|
| `GitCheckerBarApp.swift` | AppKit `@main` entry; an `NSStatusItem` + `NSPopover` hosting `MenuContent`, accessory activation (no Dock icon). The popover delegate reports open/close for the polling |
| `SingleInstance.swift` | one running copy only: an `flock` on a file in Application Support; a second launch asks the running copy to show its panel, then quits |
| `AppModel.swift` | `@Observable` state; polls the API via `URLSession` |
| `Models.swift` | `Codable` mirrors of the server's `RepoStatus` / `Summary` |
| `MenuContent.swift` | the dropdown panel, repo rows, and footer controls |
| `TerminalLauncher.swift` | opens Terminal at a repo path |
| `RepoHoverCard.swift` | the hover card: instant info, then on-demand details |
| `LoginItem.swift` | `SMAppService` "Start at login" wrapper + `launchctl` service start |
