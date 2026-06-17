import Foundation
import Observation

/// Observable application state: polls the gitchecker service and publishes the
/// latest summary + repo list to the menu bar UI.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var summary: Summary = .empty
    private(set) var repos: [RepoStatus] = []
    private(set) var lastRefresh: Date?
    /// Non-nil when the service can't be reached (e.g. daemon not running).
    private(set) var connectionError: String?
    /// True while a (potentially slower) rescan is in flight, for UI feedback.
    private(set) var isScanning = false

    /// Whether the panel is currently visible. Drives how hard we poll.
    private(set) var isPanelOpen = false

    // Poll cadences. The background poll NEVER triggers a server-side re-check
    // (that's git work); it only reads cached state. Re-checks happen on the
    // server's own timer, on panel-open, and on the Refresh button — so an idle,
    // closed menu bar costs nothing but a cheap /summary read every minute.
    private let openInterval: UInt64 = 30
    private let closedInterval: UInt64 = 60
    private let base = URL(string: "http://127.0.0.1:7878")!
    private var pollTask: Task<Void, Never>?

    private init() {}

    /// Repos worth showing, attention-first then alphabetical.
    var attentionRepos: [RepoStatus] {
        repos
            .filter { $0.needsAttention || $0.behind > 0 || $0.lastFetchError != nil || $0.error != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Headline badge count for the menu bar.
    var badgeCount: Int { summary.attention }

    /// Start the background poll. Idempotent; call once at launch.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Cheap: read cached state only. Fetch the list only when the
                // panel is open (it's the only time it's visible).
                await self.reload(trigger: nil, includeList: self.isPanelOpen)
                let secs = self.isPanelOpen ? self.openInterval : self.closedInterval
                try? await Task.sleep(nanoseconds: secs * 1_000_000_000)
            }
        }
    }

    /// The panel became visible: pull fresh, fully re-checked data right now.
    func panelOpened() {
        isPanelOpen = true
        Task { await self.refresh(forceCheck: true) }
    }

    /// The panel was hidden: drop back to the cheap badge-only idle poll.
    func panelClosed() {
        isPanelOpen = false
    }

    /// Re-inspect known repos server-side (if `forceCheck`), then reload. This is
    /// what makes Refresh pick up a repo you just cleaned — `POST /check` is
    /// synchronous, so the data read afterwards reflects current on-disk state.
    func refresh(forceCheck: Bool = true) async {
        await reload(trigger: forceCheck ? "check" : nil, includeList: true)
    }

    /// Re-discover repos under the configured roots (finds new ones / prunes
    /// gone ones), then reload. `POST /scan` is synchronous and also re-checks.
    func rescan() async {
        isScanning = true
        await reload(trigger: "scan", includeList: true)
        isScanning = false
    }

    /// POST `trigger` (if any), then GET `/summary` (always) and `/repos` (only
    /// when `includeList`).
    private func reload(trigger: String?, includeList: Bool) async {
        do {
            if let trigger {
                try await post(trigger)
            }
            let summary: Summary = try await get("summary")
            self.summary = summary
            if includeList {
                let repos: [RepoStatus] = try await get("repos")
                self.repos = repos
            }
            self.connectionError = nil
            self.lastRefresh = Date()
        } catch {
            self.connectionError = friendlyError(error)
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent(path))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private func post(_ path: String) async throws {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }

    private func friendlyError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                return "service not running"
            case .timedOut:
                return "service timed out"
            default:
                return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
