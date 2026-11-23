import SwiftUI
import GRDB
import AppKit

/// The Cut Room's left rail: the day's footage as a working stack you move
/// through, with per-source progress (reviewed / has-clips / not-seen) and a
/// clip count. Picking a row switches the player to that source *in place* —
/// no bounce back to the grid — and "Mark reviewed & next" advances through the
/// session. This is the core of the re-envisioning: flow through a shoot.
struct SessionRailView: View {
    let currentSourceID: Int64
    var onPick: (Int64) -> Void

    @EnvironmentObject private var appState: AppState
    @State private var loadTask: Task<Void, Never>?
    @State private var loadGeneration = UUID()
    @State private var sources: [Source] = []
    @State private var clipCounts: [Int64: Int] = [:]
    @State private var dayLabel: String = ""

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()

    private var reviewedCount: Int { sources.filter(\.isReviewed).count }
    private var currentIsReviewed: Bool {
        sources.first { $0.id == currentSourceID }?.isReviewed ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(dayLabel.isEmpty ? "This session" : dayLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    ProgressView(value: Double(reviewedCount), total: Double(max(1, sources.count)))
                        .tint(Theme.accent)
                        .frame(width: 92)
                    Text("\(reviewedCount)/\(sources.count) reviewed")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(sources) { src in row(src) }
                }
                .padding(8)
            }

            Divider().overlay(Theme.border)

            Button { markReviewedAndNext() } label: {
                Label(
                    currentIsReviewed ? "Reviewed — next" : "Mark reviewed & next",
                    systemImage: currentIsReviewed ? "checkmark.circle.fill" : "checkmark.circle"
                )
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
            .padding(10)
        }
        // No fixed width: as the Cut Room's left column it fills the
        // NavigationSplitView sidebar width set in RootView.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.bgRaised)
        .onAppear(perform: load)
        .onDisappear { loadTask?.cancel(); loadGeneration = UUID() }
        .onChange(of: currentSourceID) { _, _ in load() }
        .onChange(of: appState.libraryRevision) { _, _ in load() }
    }

    @ViewBuilder
    private func row(_ src: Source) -> some View {
        let isCurrent = src.id == currentSourceID
        let count = src.id.flatMap { clipCounts[$0] } ?? 0
        Button { if let id = src.id { onPick(id) } } label: {
            HStack(spacing: 8) {
                SessionThumb(source: src)
                    .frame(width: 46, height: 27)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 1))
                    .overlay(alignment: .bottomTrailing) {
                        if src.isReviewed {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.success)
                                .background(Circle().fill(.black.opacity(0.5)))
                                .padding(1)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(src.displayName)
                        .font(.system(size: 11))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(isCurrent ? Theme.textPrimary : Theme.textSecondary)
                    Text(statusLine(count: count, reviewed: src.isReviewed, current: isCurrent))
                        .font(.system(size: 10))
                        .foregroundStyle(count > 0 ? Theme.accent : Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.r2)
                    .fill(isCurrent ? Theme.surfaceActive : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func statusLine(count: Int, reviewed: Bool, current: Bool) -> String {
        if count > 0 { return "\(count) clip\(count == 1 ? "" : "s")" }
        if current { return "marking…" }
        return reviewed ? "reviewed" : "not seen"
    }

    private func markReviewedAndNext() {
        guard let store = AppEnvironment.shared.markerStore else { return }
        do { try store.markSourceReviewed(currentSourceID, reviewed: true) }
        catch {
            appState.showToast("Couldn't mark source reviewed: \(error.localizedDescription)", level: .error)
            return
        }
        // Reflect the change locally right away so the next-pick and progress
        // label don't depend on the async reload landing first.
        if let i = sources.firstIndex(where: { $0.id == currentSourceID }) {
            sources[i].reviewedAt = Int64(Date().timeIntervalSince1970)
        }
        // Advance to the next not-yet-reviewed source after the current one,
        // wrapping to any earlier unreviewed source if we're at the end.
        if let idx = sources.firstIndex(where: { $0.id == currentSourceID }) {
            let after = sources[(idx + 1)...].first { !$0.isReviewed }
            let before = sources[..<idx].first { !$0.isReviewed }
            if let next = (after ?? before)?.id { onPick(next) }
        }
    }

    private func load() {
        let current = currentSourceID
        let dayFormatter = Self.dayFmt
        loadTask?.cancel()
        let generation = UUID()
        loadGeneration = generation
        guard let db = AppEnvironment.shared.database else { return }
        loadTask = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
            let cur: Source? = try? db.read { try Source.fetchOne($0, key: current) }
            var rows: [Source] = []
            var label = ""
            if let cur, let createdAt = cur.createdAt, createdAt > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(createdAt))
                let cal = Calendar.current
                let start = cal.startOfDay(for: date)
                let end = cal.date(byAdding: .day, value: 1, to: start) ?? date
                let s = Int64(start.timeIntervalSince1970)
                let e = Int64(end.timeIntervalSince1970)
                rows = (try? db.read { dbc in
                    try Source.fetchAll(
                        dbc,
                        sql: """
                            SELECT * FROM sources
                            WHERE COALESCE(created_at, imported_at) >= ?
                              AND COALESCE(created_at, imported_at) < ?
                            ORDER BY COALESCE(created_at, imported_at) ASC
                        """,
                        arguments: [s, e]
                    )
                }) ?? []
                label = dayFormatter.string(from: date)
            }
            // Fallback when the source has no recording date: show the most
            // recently imported sources so the rail is never empty.
            if rows.isEmpty {
                rows = (try? db.read { dbc in
                    try Source.fetchAll(dbc, sql: "SELECT * FROM sources ORDER BY imported_at DESC, id ASC")
                }) ?? []
            }
            let counts: [Int64: Int] = (try? db.read { dbc -> [Int64: Int] in
                var m: [Int64: Int] = [:]
                let cursor = try Row.fetchCursor(dbc, sql: "SELECT source_id, COUNT(*) AS c FROM clips GROUP BY source_id")
                while let r = try cursor.next() {
                    let sid: Int64? = r["source_id"]
                    let c: Int? = r["c"]
                    if let sid, let c { m[sid] = c }
                }
                return m
            }) ?? [:]
            return (rows, label, counts)
            }.value
            guard !Task.isCancelled, loadGeneration == generation, currentSourceID == current else { return }
            self.sources = result.0
            self.dayLabel = result.1
            self.clipCounts = result.2
        }
    }
}

/// Tiny cached thumbnail for a session-rail row. Generates the thumbnail on
/// demand if it isn't cached yet (e.g. a freshly imported source), so the rail
/// doesn't sit on the film placeholder forever.
private struct SessionThumb: View {
    let source: Source
    @State private var img: NSImage?
    @State private var generation = UUID()

    var body: some View {
        Group {
            if let img {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Theme.surface)
                    .overlay(
                        Image(systemName: "film")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    )
            }
        }
        .clipped()
        .task(id: source.hash) { loadThumb() }
        .onDisappear { generation = UUID() }
    }

    private func loadThumb() {
        guard let engine = AppEnvironment.shared.thumbnailEngine else { return }
        let requested = UUID()
        generation = requested
        img = nil
        let p = engine.thumbPath(for: source.hash)
        if let i = NSImage(contentsOf: p) { img = i; return }
        // Missing (never generated, or cache purged) — build it on demand. The
        // engine de-dupes concurrent requests internally.
        engine.generateThumbnail(source: source) { resultURL in
            guard let resultURL, let i = NSImage(contentsOf: resultURL) else { return }
            Task { @MainActor in
                guard generation == requested else { return }
                self.img = i
            }
        }
    }
}
