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

**Polling is battery-conscious.** The background poll only reads cached state —
it never triggers a server-side git re-check. When the panel is closed it just
refreshes the badge (`GET /summary`) every 60s; when open it also pulls the list
(`GET /repos`) every 30s. A full re-check (`POST /check`) happens only on
panel-open, the Refresh button, or the server's own 5-minute timer — so an idle,
closed tray costs essentially nothing.

The panel footer has three actions (also on the icon's
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

## Build

`dotnet run` is for development. `build.ps1` produces a runnable build:

```powershell
clients\wingitchecker\build.ps1                 # framework-dependent publish → .\publish
clients\wingitchecker\build.ps1 -SelfContained  # standalone exe (bundles the .NET runtime)
clients\wingitchecker\build.ps1 -Mode build     # just compile → bin\Release
```

It warns and exits if the .NET SDK isn't on `PATH`.

## Later: run at login

Build with `build.ps1` (above), then drop a shortcut to the published
`WinGitChecker.exe` into your startup folder:

```powershell
#   shell:startup   (Win+R → shell:startup)
```

The **server** is the part that runs as a background **Windows service** — see
[`dist\windows\install-service.ps1`](../../dist/windows/install-service.ps1) and
the [root README](../../README.md#install-windows). This tray app is a separate,
user-level client.

Packaging (a signed `.exe` / MSIX) is a future step.
