# GitCheckerBar — macOS menu bar client

A SwiftUI menu bar app for the gitchecker service. Shows the count of repos that
need attention and lets you jump straight into any of them.

## Requirements

- macOS 14+ (uses `MenuBarExtra` + the Observation framework)
- The gitchecker service running locally (default `http://127.0.0.1:7878`)

## Run

```sh
cd clients/menubar
swift run            # builds and launches; lives in the menu bar (no Dock icon)
```

The menu bar item shows:

- a ⚠ icon with the **attention count** when repos need it, or a ✓ when all clean;
- a click-through panel listing repos with compact badges:
  `↑N` ahead · `↓N` behind · `●` working-tree changes · `⚑N` stashes ·
  `detached` · `⚠` fetch failed.

**Clicking a repo opens Terminal at its folder** (`open -a Terminal <path>`).

It polls `GET /summary` and `GET /repos` every 30s; **Refresh** forces an update.
If the service isn't running it shows "service not running" instead of failing.

## Architecture

| File | Role |
|------|------|
| `GitCheckerBarApp.swift` | `@main` app; `MenuBarExtra` + accessory activation (no Dock icon) |
| `AppModel.swift` | `@Observable` state; polls the API via `URLSession` |
| `Models.swift` | `Codable` mirrors of the server's `RepoStatus` / `Summary` |
| `MenuContent.swift` | the dropdown panel and repo rows |
| `TerminalLauncher.swift` | opens Terminal at a repo path |

## Later: run at login

`swift run` is for development. To have it start at login like the daemon, build
a release binary, wrap it in a `.app` bundle, and add a LaunchAgent (or drop the
bundle into System Settings → General → Login Items). Packaging is a future step.
