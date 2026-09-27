import Foundation
import Darwin

/// Ensures only one GitCheckerBar runs at a time, however it was launched
/// (Finder, `open -n`, login item, the raw binary, a dev build at another path).
///
/// Uses an exclusive `flock` on a file in the app's support directory. The lock
/// belongs to the open file descriptor, so the kernel releases it when the
/// process exits — even on a crash — and a stale lock can never block startup.
@MainActor
enum SingleInstance {
    /// Posted by a second launch to ask the running instance to show its panel.
    static let showNotification = Notification.Name("com.user.gitcheckerbar.show")

    /// Held open for the whole process lifetime; closing it would drop the lock.
    private static var lockFD: Int32 = -1

    /// Try to become the single running instance. Returns false if another
    /// instance already holds the lock.
    static func acquire() -> Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("gitchecker")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("menubar.lock").path

        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        // If the lock file can't be opened at all, don't refuse to run over it.
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd
            return true
        }
        close(fd)
        return false
    }

    /// Ask the running instance to show its panel.
    static func signalRunningInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            showNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
