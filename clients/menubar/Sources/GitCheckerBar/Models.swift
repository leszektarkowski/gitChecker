import Foundation

/// Sync relationship with upstream. Mirrors the server's tagged enum:
/// `{"kind":"none"}` or `{"kind":"tracking","name":...,"ahead":N,"behind":N}`.
struct Upstream: Decodable {
    let kind: String
    let name: String?
    let ahead: Int?
    let behind: Int?

    var isTracking: Bool { kind == "tracking" }
}

/// One repository's status, decoded from `GET /repos`.
/// JSON is snake_case; the decoder is configured with `.convertFromSnakeCase`.
struct RepoStatus: Decodable, Identifiable {
    let id: String
    let path: String
    let branch: String?
    let detachedHead: Bool
    let hasStaged: Bool
    let hasUnstaged: Bool
    let hasUntracked: Bool
    let stashCount: Int
    let operation: String
    let upstream: Upstream
    let error: String?
    let lastChecked: Int?
    let lastFetched: Int?
    let lastFetchError: String?

    /// Last path component, for display.
    var name: String { (path as NSString).lastPathComponent }

    var ahead: Int { upstream.ahead ?? 0 }
    var behind: Int { upstream.behind ?? 0 }

    var hasWorkingTreeChanges: Bool { hasStaged || hasUnstaged || hasUntracked }
    var operationInProgress: Bool { operation != "clean" }

    /// Mirrors the server's `is_dirty`: any local work at risk.
    var needsAttention: Bool {
        hasWorkingTreeChanges
            || stashCount > 0
            || operationInProgress
            || ahead > 0
    }

    /// Compact status badges for a row, e.g. ["↑2", "●", "↓1", "⚠"].
    var badges: [String] {
        var out: [String] = []
        if ahead > 0 { out.append("↑\(ahead)") }
        if behind > 0 { out.append("↓\(behind)") }
        if hasWorkingTreeChanges { out.append("●") }
        if stashCount > 0 { out.append("⚑\(stashCount)") }
        if operationInProgress { out.append(operation) }
        if detachedHead { out.append("detached") }
        if lastFetchError != nil { out.append("⚠") }
        if error != nil { out.append("error") }
        return out
    }
}

/// Aggregate counts, decoded from `GET /summary`.
struct Summary: Decodable {
    let total: Int
    let attention: Int
    let uncommitted: Int
    let ahead: Int
    let behind: Int
    let stashed: Int
    let inProgress: Int
    let fetchErrors: Int
    let readErrors: Int

    static let empty = Summary(
        total: 0, attention: 0, uncommitted: 0, ahead: 0, behind: 0,
        stashed: 0, inProgress: 0, fetchErrors: 0, readErrors: 0)
}
