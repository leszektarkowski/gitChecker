import SwiftUI

/// Card shown beside a repo row after a short hover.
///
/// Two stages: everything the app already knows is shown instantly (no I/O);
/// the file-level "git status" detail, last commit, remote and stash messages
/// are fetched from the server when the card appears (a scan of this one repo)
/// and filled in underneath.
struct RepoHoverCard: View {
    let repo: RepoStatus
    let model: AppModel

    @State private var details: RepoDetails?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(repo.name).font(.headline)
            Text(repo.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Divider()
            instant

            Divider()
            if let details {
                loaded(details)
            } else if failed {
                Text("Couldn't load details.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading changes…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        // Cancelled automatically if the card closes before it finishes.
        .task {
            if let d = await model.details(for: repo.id) { details = d } else { failed = true }
        }
    }

    // MARK: Stage 1 — already known, shown instantly

    @ViewBuilder private var instant: some View {
        line("arrow.triangle.branch", branchText)
        if case .some(let sync) = syncText { line("arrow.up.arrow.down", sync) }
        line("doc.on.doc", workingTreeText)
        if repo.operationInProgress {
            line("exclamationmark.triangle", "\(repo.operation) in progress", tint: .orange)
        }
        if repo.stashCount > 0 {
            line("tray.full", repo.stashCount == 1 ? "1 stash" : "\(repo.stashCount) stashes")
        }
        line("clock", fetchedText)
        if let err = repo.lastFetchError {
            line("exclamationmark.icloud", "Fetch failed: \(condensed(err))", tint: .orange, lines: 3)
        }
        if let err = repo.error {
            line("xmark.octagon", "Can't read repo: \(err)", tint: .red, lines: 3)
        }
    }

    private var branchText: String {
        if repo.detachedHead { return "detached HEAD" }
        let branch = repo.branch ?? "no branch yet"
        if repo.upstream.isTracking, let up = repo.upstream.name { return "\(branch) → \(up)" }
        return "\(branch) · no upstream"
    }

    private var syncText: String? {
        guard repo.upstream.isTracking else { return nil }
        var parts: [String] = []
        if repo.ahead > 0 { parts.append("\(repo.ahead) to push") }
        if repo.behind > 0 { parts.append("\(repo.behind) to pull") }
        return parts.isEmpty ? "up to date with upstream" : parts.joined(separator: " · ")
    }

    private var workingTreeText: String {
        var parts: [String] = []
        if repo.hasStaged { parts.append("staged") }
        if repo.hasUnstaged { parts.append("unstaged") }
        if repo.hasUntracked { parts.append("untracked") }
        return parts.isEmpty ? "working tree clean" : parts.joined(separator: ", ") + " changes"
    }

    private var fetchedText: String {
        guard let t = repo.lastFetched else { return "never fetched" }
        return "fetched " + relative(t)
    }

    // MARK: Stage 2 — fetched on demand

    @ViewBuilder private func loaded(_ d: RepoDetails) -> some View {
        if let c = d.lastCommit {
            line("text.bubble", "“\(c.summary)” — \(c.author), \(relative(c.time))", lines: 2)
        }
        if let url = d.remoteUrl {
            line("network", url, lines: 1)
        }
        group("Conflicted", d.conflicted, color: .red)
        group("Staged", d.staged, color: .green)
        group("Not staged", d.unstaged, color: .orange)
        group("Untracked", d.untracked, color: .secondary)
        if !d.stashes.isEmpty {
            Text("Stashes").font(.caption.bold()).padding(.top, 2)
            ForEach(d.stashes, id: \.self) { s in
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        if d.staged.total + d.unstaged.total + d.untracked.total + d.conflicted.total == 0 {
            Text("No changed files.").font(.caption).foregroundStyle(.secondary)
        }
        if let err = d.error {
            Text(err).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ g: RepoDetails.FileGroup, color: Color) -> some View {
        if g.total > 0 {
            Text("\(title) (\(g.total))").font(.caption.bold()).padding(.top, 2)
            ForEach(g.files, id: \.self) { f in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(letter(f.kind))
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(color)
                        .frame(width: 12, alignment: .leading)
                    Text(f.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if g.total > g.files.count {
                Text("+\(g.total - g.files.count) more")
                    .font(.caption2).foregroundStyle(.secondary).padding(.leading, 18)
            }
        }
    }

    /// git-status-style one-letter code.
    private func letter(_ kind: String) -> String {
        switch kind {
        case "added": "A"
        case "modified": "M"
        case "deleted": "D"
        case "renamed": "R"
        case "typechange": "T"
        case "conflicted": "U"
        default: "?"
        }
    }

    // MARK: Helpers

    private func line(_ symbol: String, _ text: String, tint: Color = .secondary, lines: Int = 1) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 14)
            Text(text)
                .font(.callout)
                .lineLimit(lines)
                // Let multi-line text grow vertically inside the popover
                // instead of being truncated to one line.
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// git's fetch stderr is padded with boilerplate; keep the informative lines.
    private func condensed(_ message: String) -> String {
        let noise = ["Please make sure you have the correct access rights", "and the repository exists."]
        return message
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in !line.isEmpty && !noise.contains(where: line.hasPrefix) }
            .prefix(2)
            .joined(separator: "\n")
    }

    private func relative(_ unix: Int) -> String {
        RelativeDateTimeFormatter().localizedString(
            for: Date(timeIntervalSince1970: TimeInterval(unix)), relativeTo: Date())
    }
}
