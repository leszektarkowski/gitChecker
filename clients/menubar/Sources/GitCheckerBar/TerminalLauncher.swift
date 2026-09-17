import AppKit

/// Opens a repo folder using the server-configured `open_command` (with `{path}`
/// substituted). Falls back to opening Terminal when no command is configured.
enum RepoOpener {
    static func open(command: String, path: String) {
        let template = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else {
            openTerminal(at: path)
            return
        }

        // `{path}` is substituted with a shell-quoted path so spaces / special
        // characters are safe and the user doesn't have to quote it themselves.
        let cmd = template.replacingOccurrences(of: "{path}", with: shellQuote(path))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", cmd]
        // A login-item app inherits a minimal PATH; add the usual CLI locations
        // so tools like `smerge`, `code`, etc. resolve.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        proc.environment = env
        do {
            try proc.run()
        } catch {
            NSLog("GitCheckerBar: failed to run open command '\(cmd)': \(error)")
        }
    }

    private static func openTerminal(at path: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Terminal", path]
        try? proc.run()
    }

    /// Wrap in single quotes, escaping any embedded single quotes.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
