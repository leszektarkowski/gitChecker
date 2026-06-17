import Foundation
import ServiceManagement
import Observation

/// Wraps `SMAppService.mainApp` so the menu can offer a "Start at login" toggle.
/// Requires a real app bundle (it's a no-op when run unbundled via `swift run`).
@MainActor
@Observable
final class LoginItem {
    private(set) var isEnabled = false
    /// Non-nil when toggling isn't possible / needs user action.
    private(set) var note: String?

    init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            note = nil
        case .requiresApproval:
            isEnabled = false
            note = "approve in System Settings → Login Items"
        case .notFound:
            isEnabled = false
            note = "run the packaged .app to enable"
        default: // .notRegistered and any future cases
            isEnabled = false
            note = nil
        }
    }

    func setEnabled(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            note = error.localizedDescription
        }
        refresh()
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
