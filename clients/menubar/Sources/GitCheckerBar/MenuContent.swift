import SwiftUI

/// The panel shown in the popover when the menu bar item is clicked.
/// Open/close is reported by the popover delegate (see AppDelegate).
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
            if let note = login.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            footer
        }
        .padding(pad)
        .frame(width: width)
        // Report the exact ideal height; the popover sizes itself to it
        // (NSHostingController .preferredContentSize), shrinking included.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var loginRow: some View {
        HStack(spacing: 6) {
            Toggle("Start at login", isOn: Binding(
                get: { login.isEnabled },
                set: { login.setEnabled($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            .disabled(!login.canToggle)
            Spacer()
            // Open config.toml in the default text editor.
            Button("Configure…") { ConfigFile.openInEditor() }
                .buttonStyle(.borderless)
                .disabled(model.isRestarting)
            // Apply edits: restart the service (it reads config only at startup).
            Button("Restart") { Task { await model.restartService() } }
                .buttonStyle(.borderless)
                .disabled(model.isRestarting)
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

    /// Cap the visible rows so a long list can't make an oversized panel. A
    /// plain VStack (no ScrollView) lets the popover window size itself exactly
    /// to the content — a ScrollView with a fixed frame height leaves the window
    /// stuck at its largest size, showing empty margins when the list shrinks.
    private let maxVisibleRepos = 12

    private var repoList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.attentionRepos.prefix(maxVisibleRepos))) { repo in
                RepoRow(repo: repo) { RepoOpener.open(command: model.openCommand, path: repo.path) }
            }
            let extra = model.attentionRepos.count - maxVisibleRepos
            if extra > 0 {
                Text("+\(extra) more…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
        }
        .frame(width: contentWidth, alignment: .leading)
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
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            // Rescan = re-discover repo folders (find new / prune gone).
            Button("Rescan") { Task { await model.rescan() } }
                .buttonStyle(.borderless)
                .disabled(model.isScanning || model.isRestarting)
            // Refresh = re-check status of known repos.
            Button("Refresh") { Task { await model.refresh() } }
                .buttonStyle(.borderless)
                .disabled(model.isScanning || model.isRestarting)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
    }

    private var statusText: String {
        if model.isRestarting { return "restarting…" }
        if model.isScanning { return "scanning…" }
        return refreshedText
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
