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
    // Inside `pad`, every row is inset 6 pt so text lines up with the repo rows
    // and hover highlights (rows and buttons) stay within the dividers.
    private var contentWidth: CGFloat { width - 2 * pad }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            Divider()

            if let err = model.connectionError {
                offline(err)
            } else if listIsEmpty {
                if showAll { noRepos } else { allClear }
            } else {
                repoList
            }

            if model.connectionError == nil,
               model.summary.fetchErrors > 0 || model.isRetryingFetch || model.retryMessage != nil {
                fetchRetryRow
            }

            Divider()
            loginRow
            if let note = login.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
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
        HStack(spacing: 2) {
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
                .buttonStyle(.hover)
                .disabled(model.isRestarting)
            // Apply edits: restart the service (it reads config only at startup).
            Button("Restart") { Task { await model.restartService() } }
                .buttonStyle(.hover)
                .disabled(model.isRestarting)
        }
        // Buttons carry their own 6 pt padding on the trailing side.
        .padding(.leading, 6)
    }

    private var header: some View {
        HStack {
            Image(systemName: "arrow.triangle.branch")
            Text("gitchecker").font(.headline)
            Spacer()
            Picker("Show", selection: $showAll) {
                Text("Issues \(model.atRiskRepos.count)").tag(false)
                Text("All \(model.summary.total)").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 6)
    }

    private var listIsEmpty: Bool {
        showAll ? model.allRepos.isEmpty
                : model.atRiskRepos.isEmpty && model.behindOrUnreachableRepos.isEmpty
    }

    /// The list scrolls once it's taller than `maxListHeight`. The scroll area
    /// is sized to the measured content height, and the popover (unlike the old
    /// MenuBarExtra window) resizes to follow it, shrinking included.
    private var repoList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if showAll {
                    rows(model.allRepos)
                } else {
                    // Issues: at-risk repos (what the badge counts) first…
                    if model.atRiskRepos.isEmpty {
                        Label("Nothing at risk — no uncommitted or unpushed work",
                              systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                    } else {
                        rows(model.atRiskRepos)
                    }
                    // …then the ones that only need a pull or couldn't be fetched.
                    let rest = model.behindOrUnreachableRepos
                    if !rest.isEmpty {
                        Text("Behind or unreachable (\(rest.count))")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.horizontal, 6)
                        rows(rest)
                    }
                }
            }
            .frame(width: contentWidth, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listContentHeight = $0 }
        }
        .frame(height: min(listContentHeight, maxListHeight))
    }

    /// "⚠ 2 fetches failed · Retry" — re-fetches failed repos now, ignoring the
    /// backoff timer. Shown in both views: a repo can have a fetch error *and*
    /// be at risk, so it isn't always in the "Behind or unreachable" section.
    private var fetchRetryRow: some View {
        let failed = model.summary.fetchErrors
        return HStack(spacing: 6) {
            if model.isRetryingFetch {
                ProgressView().controlSize(.small)
                Text("Retrying failed fetches…").font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: failed > 0 ? "exclamationmark.icloud" : "checkmark.icloud")
                    .foregroundStyle(failed > 0 ? .orange : .green)
                Text(model.retryMessage ?? (failed == 1 ? "1 fetch failed" : "\(failed) fetches failed"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Same font and colour as the other buttons: a small grey button
            // reads as disabled.
            Button("Retry") { Task { await model.retryFailedFetches() } }
                .buttonStyle(.hover)
                .disabled(model.isRetryingFetch || failed == 0)
        }
        // Leading only: the button's own padding supplies the trailing inset,
        // lining "Retry" up with the badges in the repo rows.
        .padding(.leading, 6)
    }

    @ViewBuilder private func rows(_ repos: [RepoStatus]) -> some View {
        ForEach(repos) { repo in
            RepoRow(repo: repo, model: model) { RepoOpener.open(command: model.openCommand, path: repo.path) }
        }
    }

    private var noRepos: some View {
        HStack {
            Image(systemName: "tray").foregroundStyle(.secondary)
            Text("No repositories tracked yet — try Rescan").font(.callout)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }

    private var allClear: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("All clean — nothing needs attention").font(.callout)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
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
            .buttonStyle(.hover)
        }
        .padding(.vertical, 6)
        .padding(.leading, 6)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            // Rescan = re-discover repo folders (find new / prune gone).
            Button("Rescan") { Task { await model.rescan() } }
                .buttonStyle(.hover)
                .disabled(model.isScanning || model.isRestarting)
            // Refresh = re-check status of known repos.
            Button("Refresh") { Task { await model.refresh() } }
                .buttonStyle(.hover)
                .disabled(model.isScanning || model.isRestarting)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.hover)
        }
        .padding(.leading, 6)
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
            .background(hovering ? Color.hoverHighlight : Color.clear)
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
