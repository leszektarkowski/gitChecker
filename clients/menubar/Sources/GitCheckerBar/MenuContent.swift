import SwiftUI

/// The panel shown when the menu bar item is clicked (window style).
struct MenuContent: View {
    @Bindable var model: AppModel
    @State private var login = LoginItem()

    /// Fixed panel width. The inner content is pinned to `width - 2*padding` so a
    /// vertical ScrollView can't collapse its width when scrolling activates.
    private let width: CGFloat = 340
    private let pad: CGFloat = 10
    private var contentWidth: CGFloat { width - 2 * pad }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            Divider()

            if let err = model.connectionError {
                offline(err)
            } else if model.attentionRepos.isEmpty {
                allClear
            } else {
                repoList
            }

            Divider()
            loginRow
            footer
        }
        .padding(pad)
        .frame(width: width)
        // Best-effort panel open/close detection: fetch fresh on open, idle on
        // close. Falls back gracefully if these don't fire per-toggle.
        .onAppear { model.panelOpened() }
        .onDisappear { model.panelClosed() }
    }

    private var loginRow: some View {
        HStack(spacing: 6) {
            Toggle("Start at login", isOn: Binding(
                get: { login.isEnabled },
                set: { login.setEnabled($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            .disabled(login.note == "run the packaged .app to enable")
            if let note = login.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "arrow.triangle.branch")
            Text("gitchecker").font(.headline)
            Spacer()
            Text("\(model.summary.total) tracked")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Explicit list height: a ScrollView in a self-sizing MenuBarExtra window
    /// has no definite height and collapses to one row, so we size it to the
    /// content (estimated per-row) capped at `maxListHeight`.
    private let maxListHeight: CGFloat = 380
    private var listHeight: CGFloat {
        let perRow: CGFloat = 44
        return min(CGFloat(model.attentionRepos.count) * perRow, maxListHeight)
    }

    private var repoList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.attentionRepos) { repo in
                    RepoRow(repo: repo) { TerminalLauncher.open(at: repo.path) }
                }
            }
            // Pin to a definite width so the ScrollView can't collapse it.
            .frame(width: contentWidth, alignment: .leading)
        }
        .frame(height: listHeight)
    }

    private var allClear: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("All clean — nothing needs attention").font(.callout)
        }
        .padding(.vertical, 6)
    }

    private func offline(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).foregroundStyle(.secondary)
            Spacer()
            // Try to (re)start the launchd service, then reload shortly after.
            Button("Start") {
                ServiceControl.start()
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await model.refresh()
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(model.isScanning ? "scanning…" : refreshedText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            // Rescan = re-discover repo folders (find new / prune gone).
            Button("Rescan") { Task { await model.rescan() } }
                .buttonStyle(.borderless)
                .disabled(model.isScanning)
            // Refresh = re-check status of known repos.
            Button("Refresh") { Task { await model.refresh() } }
                .buttonStyle(.borderless)
                .disabled(model.isScanning)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
    }

    private var refreshedText: String {
        guard let last = model.lastRefresh else { return "never refreshed" }
        let secs = Int(Date().timeIntervalSince(last))
        return secs < 2 ? "refreshed just now" : "refreshed \(secs)s ago"
    }
}

/// A single clickable repo row: name, branch, and compact status badges.
private struct RepoRow: View {
    let repo: RepoStatus
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.name).font(.body)
                    if let branch = repo.branch {
                        Text(branch).font(.caption2).foregroundStyle(.secondary)
                    } else if repo.detachedHead {
                        Text("detached HEAD").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(repo.badges.joined(separator: " "))
                    .font(.caption.monospaced())
                    .foregroundStyle(repo.lastFetchError != nil || repo.error != nil ? .orange : .primary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.secondary.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(repo.path)
        .onHover { hovering = $0 }
    }
}
