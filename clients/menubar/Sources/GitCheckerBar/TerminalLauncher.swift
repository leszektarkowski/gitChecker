import AppKit

/// Opens Terminal.app with the working directory set to a repo path.
enum TerminalLauncher {
    static func open(at path: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Terminal", path]
        do {
            try proc.run()
        } catch {
            NSLog("GitCheckerBar: failed to open Terminal at \(path): \(error)")
        }
    }
}
