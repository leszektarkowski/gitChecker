# WinGitChecker — Windows system tray client

A Windows system-tray app for the gitchecker service. The Windows counterpart of
the [macOS menu bar client](../menubar) — shows the count of repos that need
attention and lets you jump straight into any of them.

## Requirements

- Windows 10/11 with the [.NET 10 SDK](https://dotnet.microsoft.com/download)
  (or newer) — uses WinForms (`net10.0-windows`)
- The gitchecker service running locally (default `http://127.0.0.1:7878`)

No NuGet packages — it's pure WinForms + `System.Text.Json` from the framework.

## Run

```powershell
cd clients\wingitchecker
dotnet run -c Release      # builds and launches into the system tray (no taskbar window)
```

The tray icon shows:

- an **amber circle with the attention count** when repos need it, or a green
  **✓** when everything is clean;
- the tooltip summarizes state (`gitchecker — 2 need attention` / `all clean` /
  `service not running`).

**Left-click the icon** to open a panel listing repos with compact badges:
`↑N` ahead · `↓N` behind · `●` working-tree changes · `⚑N` stashes ·
`detached` · `⚠` fetch failed · `error`.

**Clicking a repo opens a terminal at its folder** — Windows Terminal (`wt.exe -d
<path>`) if installed, otherwise PowerShell rooted in the folder.

It polls every 30s. The panel footer has three actions (also on the icon's
**right-click** menu):

- **Refresh** — re-check the status of *known* repos (picks up a repo you just
  cleaned or changed). Backed by the synchronous `POST /check`.
- **Rescan** — re-discover repo folders under the configured roots: finds repos
  added since the last scan and prunes ones that are gone. Backed by the
  synchronous `POST /scan`. Shows "scanning…" while it runs.
- **Quit** — exit the app.

If the service isn't running it shows "service not running" instead of failing.

## Architecture

Mirrors the macOS client's structure:

| File | Role | macOS equivalent |
|------|------|------------------|
| `Program.cs` | `[STAThread]` entry point; runs the `TrayApp` context | `GitCheckerBarApp.swift` |
| `TrayApp.cs` | `NotifyIcon` host (tray-only agent, no taskbar window) | `GitCheckerBarApp.swift` |
| `AppModel.cs` | polls the API via `HttpClient`; raises `Changed` | `AppModel.swift` |
| `Models.cs` | `RepoStatus` / `Summary` / `Upstream` JSON mirrors | `Models.swift` |
| `PanelForm.cs` | the popup panel and repo rows | `MenuContent.swift` |
| `IconRenderer.cs` | draws the count/✓ tray icon at runtime | (menu bar label) |
| `TerminalLauncher.cs` | opens a terminal at a repo path | `TerminalLauncher.swift` |

## Later: run at login

`dotnet run` is for development. To start it at login like the daemon, publish a
self-contained binary and add it to your startup:

```powershell
dotnet publish -c Release -r win-x64 --self-contained
# then drop a shortcut to the published WinGitChecker.exe into:
#   shell:startup   (Win+R → shell:startup)
```

Packaging (a signed `.exe` / MSIX) is a future step.
