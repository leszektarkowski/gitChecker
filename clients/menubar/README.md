# GitCheckerBar — macOS menu bar client

A SwiftUI menu bar app for the gitchecker service. Shows the count of repos that
need attention and lets you jump straight into any of them.

## Requirements

- macOS 14+ (uses `MenuBarExtra` + the Observation framework)
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
  `detached` · `⚠` fetch failed.

**Clicking a repo opens Terminal at its folder** (`open -a Terminal <path>`).

It polls every 30s. The footer has:

- **Refresh** — re-check the status of *known* repos (picks up a repo you just
  cleaned or changed). Backed by the synchronous `POST /check`.
- **Rescan** — re-discover repo folders under the configured roots: finds repos
  added since the last scan and prunes ones that are gone. Backed by the
  synchronous `POST /scan`. Shows "scanning…" while it runs.
- **Start at login** — a checkbox that registers/unregisters the app as a login
  item via `SMAppService` (only effective when run as the installed `.app`, not
  via `swift run`).

If the service isn't running it shows "service not running" with a **Start**
button that runs `launchctl kickstart` on the LaunchAgent.

## Architecture

| File | Role |
|------|------|
| `GitCheckerBarApp.swift` | `@main` app; `MenuBarExtra` + accessory activation (no Dock icon) |
| `AppModel.swift` | `@Observable` state; polls the API via `URLSession` |
| `Models.swift` | `Codable` mirrors of the server's `RepoStatus` / `Summary` |
| `MenuContent.swift` | the dropdown panel, repo rows, and footer controls |
| `TerminalLauncher.swift` | opens Terminal at a repo path |
| `LoginItem.swift` | `SMAppService` "Start at login" wrapper + `launchctl` service start |
