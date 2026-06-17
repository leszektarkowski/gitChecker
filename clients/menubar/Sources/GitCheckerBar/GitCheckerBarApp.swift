import SwiftUI
import AppKit

/// Makes the process a pure menu bar agent (no Dock icon, no main window) and
/// starts the background poll at launch (so the badge updates without the panel
/// ever being opened).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.start()
    }
}

@main
struct GitCheckerBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            // Icon + count as sibling views so BOTH render in the status item:
            // Text-with-interpolated-Image drops the glyph, and a plain Label
            // renders icon-only. An HStack keeps the symbol and the number.
            HStack(spacing: 2) {
                Image(systemName: model.badgeCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle")
                if model.badgeCount > 0 {
                    Text("\(model.badgeCount)")
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
