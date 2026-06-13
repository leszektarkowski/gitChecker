import Foundation
import Observation

/// Observable application state: polls the gitchecker service and publishes the
/// latest summary + repo list to the menu bar UI.
@MainActor
@Observable
final class AppModel {
    private(set) var summary: Summary = .empty
    private(set) var repos: [RepoStatus] = []
    private(set) var lastRefresh: Date?
    /// Non-nil when the service can't be reached (e.g. daemon not running).
    private(set) var connectionError: String?

    /// How often to poll, in seconds.
    private let pollInterval: UInt64 = 30
    private let base = URL(string: "http://127.0.0.1:7878")!
    private var pollTask: Task<Void, Never>?

    /// Repos worth showing, attention-first then alphabetical.
    var attentionRepos: [RepoStatus] {
        repos
            .filter { $0.needsAttention || $0.behind > 0 || $0.lastFetchError != nil || $0.error != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Headline badge count for the menu bar.
    var badgeCount: Int { summary.attention }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: (self?.pollInterval ?? 30) * 1_000_000_000)
            }
        }
    }

    /// Re-inspect repos server-side (if `forceCheck`), then fetch `/summary` and
    /// `/repos`. `POST /check` is synchronous, so the data read afterwards
    /// reflects the current on-disk state — that's what makes Refresh actually
    /// pick up a repo you just cleaned.
    func refresh(forceCheck: Bool = true) async {
        do {
            if forceCheck {
                try await post("check")
            }
            let summary: Summary = try await get("summary")
            let repos: [RepoStatus] = try await get("repos")
            self.summary = summary
            self.repos = repos
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
