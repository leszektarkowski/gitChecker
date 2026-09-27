import Foundation
import ServiceManagement
import Observation

/// Wraps `SMAppService.mainApp` so the menu can offer a "Start at login" toggle.
/// Requires a real app bundle (it's a no-op when run unbundled via `swift run`).
@MainActor
@Observable
final class LoginItem {
    private(set) var isEnabled = false
    /// Non-nil when toggling needs user action or the last attempt failed.
    private(set) var note: String?

    /// SMAppService needs a real app bundle; under `swift run` there is none.
    /// Decide this from the bundle itself — NOT from `status == .notFound`,
    /// which is also what a bundled app reports before its first register().
    let canToggle = Bundle.main.bundleURL.pathExtension == "app"
        && Bundle.main.bundleIdentifier != nil

    init() {
        refresh()
    }

    func refresh() {
        guard canToggle else {
            isEnabled = false
            note = "run the packaged .app to enable"
            return
        }
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            note = nil
        case .requiresApproval:
            isEnabled = false
            note = "approve in System Settings → Login Items"
        default: // .notRegistered / .notFound (never registered yet) / future cases
            isEnabled = false
            note = nil
        }
    }

    func setEnabled(_ on: Bool) {
        var failure: String?
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            failure = error.localizedDescription
        }
        refresh()
        // Set after refresh() so the error isn't immediately overwritten.
        if let failure { note = failure }
    }
}

/// Best-effort start of the gitchecker LaunchAgent (if it's installed) so the GUI
/// can recover from a stopped service without the user touching the terminal.
enum ServiceControl {
    static func start() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["kickstart", "-k", "gui/\(getuid())/com.user.gitchecker"]
        try? proc.run()
    }
}
