import SwiftUI
import AppKit

/// Makes the process a pure menu bar agent (no Dock icon, no main window).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct GitCheckerBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
                .task { model.start() }
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
