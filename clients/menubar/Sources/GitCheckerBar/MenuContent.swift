import SwiftUI

/// The panel shown in the popover when the menu bar item is clicked.
/// Open/close is reported by the popover delegate (see AppDelegate).
struct MenuContent: View {
    @Bindable var model: AppModel
    @State private var login = LoginItem()
    /// Show every tracked repo instead of only those needing attention.
    /// Remembered across launches.
    @AppStorage("showAllRepos") private var showAll = false
    /// Measured height of the list's content, so the scroll area is exactly as
    /// tall as the rows (no per-row estimate) up to `maxListHeight`.
    @State private var listContentHeight: CGFloat = 0
    /// ~11.5 rows: deliberately not a whole number of rows, so a half-visible
    /// last row hints that the list scrolls (macOS hides idle scrollbars).
    private let maxListHeight: CGFloat = 460

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
            } else if shownRepos.isEmpty {
                if showAll { noRepos } else { allClear }
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
            Picker("Show", selection: $showAll) {
                Text("Issues \(model.attentionRepos.count)").tag(false)
                Text("All \(model.summary.total)").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }

    private var shownRepos: [RepoStatus] {
        showAll ? model.allRepos : model.attentionRepos
    }

    /// The list scrolls once it's taller than `maxListHeight`. The scroll area
    /// is sized to the measured content height, and the popover (unlike the old
    /// MenuBarExtra window) resizes to follow it, shrinking included.
    private var repoList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(shownRepos) { repo in
                    RepoRow(repo: repo, model: model) { RepoOpener.open(command: model.openCommand, path: repo.path) }
                }
            }
            .frame(width: contentWidth, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listContentHeight = $0 }
        }
        .frame(height: min(listContentHeight, maxListHeight))
    }

    private var noRepos: some View {
        HStack {
            Image(systemName: "tray").foregroundStyle(.secondary)
            Text("No repositories tracked yet — try Rescan").font(.callout)
        }
        .padding(.vertical, 6)
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
    let model: AppModel
    let action: () -> Void
    @State private var hovering = false
    /// Hover card, opened only after the pointer rests on the row briefly, so
    /// sweeping across the list doesn't flash cards or trigger scans.
    @State private var showCard = false
    @State private var hoverTask: Task<Void, Never>?
    private let hoverDelay: UInt64 = 400_000_000 // 0.4 s

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
                if repo.badges.isEmpty {
                    // Clean (only visible in the "All" view).
                    Text("✓").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(repo.badges.joined(separator: " "))
                        .font(.caption.monospaced())
                        .foregroundStyle(repo.lastFetchError != nil || repo.error != nil ? .orange : .primary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.secondary.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            hoverTask?.cancel()
            if inside {
                hoverTask = Task {
                    try? await Task.sleep(nanoseconds: hoverDelay)
                    if !Task.isCancelled { showCard = true }
                }
            } else {
                showCard = false
            }
        }
        .popover(isPresented: $showCard, arrowEdge: .leading) {
            RepoHoverCard(repo: repo, model: model)
        }
    }
}
