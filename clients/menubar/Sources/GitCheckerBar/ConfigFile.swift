import AppKit

/// Locates and opens the server's config file. The path mirrors what the Rust
/// `directories` crate resolves to on macOS:
/// `~/Library/Application Support/gitchecker/config.toml`.
enum ConfigFile {
    static var path: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("gitchecker/config.toml")
    }

    /// Open the config in the default text editor. If it doesn't exist yet (the
    /// service has never run), nudge the service to create the default first;
    /// fall back to revealing the folder in Finder.
    static func openInEditor() {
        let url = path
        if !FileManager.default.fileExists(atPath: url.path) {
            // The server writes a default config on startup — kick it, then open.
            ServiceControl.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if FileManager.default.fileExists(atPath: url.path) {
                    open(url)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
                }
            }
            return
        }
        open(url)
    }

    /// `open -t` uses the default *text* editor, which is reliable for `.toml`
    /// (it often has no file-type association of its own).
    private static func open(_ url: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-t", url.path]
        try? proc.run()
    }
}
