import SwiftUI
import AppKit
import Observation

/// Owns the menu bar item and its popover.
///
/// We use AppKit's `NSStatusItem` + `NSPopover` rather than SwiftUI's
/// `MenuBarExtra(.window)`: the MenuBarExtra window sizes itself opaquely and
/// doesn't follow the content when it changes after the panel appears (e.g. at
/// login, when the list arrives late) — leaving empty space above the content.
/// An `NSHostingController` with `.preferredContentSize` makes the popover track
/// the SwiftUI content exactly, and the popover delegate gives us reliable
/// open/close events for the battery-conscious polling.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private(set) static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)

        let model = AppModel.shared
        model.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageLeading
        }
        updateBadge()

        let host = NSHostingController(rootView: MenuContent(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient // close on click outside, like a menu
        popover.animates = false
        popover.delegate = self

    }

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            // Accessory apps must be active for the transient popover to take
            // key and close when you click elsewhere. Activate *before* showing:
            // activating afterwards counts as a focus change and dismisses it.
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverWillShow(_ notification: Notification) { AppModel.shared.panelOpened() }
    func popoverDidClose(_ notification: Notification) { AppModel.shared.panelClosed() }

    /// Keep the status item's icon + count in sync with the model.
    private func updateBadge() {
        let count = withObservationTracking {
            AppModel.shared.badgeCount
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateBadge() }
        }
        guard let button = statusItem.button else { return }
        let symbol = count > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "gitchecker")
        image?.isTemplate = true
        button.image = image
        button.title = count > 0 ? " \(count)" : ""
    }
}

@main
struct GitCheckerBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // Everything lives in the status item / popover owned by the delegate; the
    // app needs at least one scene, and Settings shows nothing until invoked.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
