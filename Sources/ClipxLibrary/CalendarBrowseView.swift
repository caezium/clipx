import SwiftUI

/// Browse sources grouped by their recording date (NOT import date). Renders
/// a vertical timeline: most recent month at the top, expandable day sections
/// inside. Designed for the "I shot this on the karting weekend in May"
/// workflow where you remember a date but not a filename.
struct CalendarBrowseView: View {
    let sources: [Source]
    var clips: [Clip] = []
    @EnvironmentObject private var appState: AppState
    /// Months collapsed to a one-line header. Default: every month except the
    /// most recent — so a big library opens calm, showing this month only.
    @State private var collapsedMonths: Set<String> = []
    /// Days expanded to a thumbnail grid. Default: the most recent couple of
    /// shoot days. Everything older stays a compact, tappable summary row.
    @State private var expandedDays: Set<String> = []
    /// Memoized group buckets. The computation is O(N log N) over the sources
    /// array, and was previously re-run on every body invalidation. Now it
    /// runs only when `sources` actually changes.
    @State private var groups: [MonthGroup] = []
    /// Smart defaults are applied once, and again whenever the month/day
    /// structure changes — but not on incidental reloads (e.g. tagging), so the
    /// user's manual expand/collapse survives a `libraryRevision` bump.
    @State private var didApplyDefaults = false

    /// How many of the most recent shoot days open automatically.
    private static let autoExpandRecentDays = 2

    // DateFormatter is expensive to allocate; keep one static.
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 12)]

    struct DayGroup: Identifiable {
        let id: String
        let date: Date
        let sources: [Source]
    }
    struct MonthGroup: Identifiable {
        let id: String
        let date: Date
        let days: [DayGroup]
        var totalCount: Int { days.reduce(0) { $0 + $1.sources.count } }
    }

    /// Groups by month-day in chronological-descending order. Sources without
    /// a `created_at` fall under "No recording date" at the end.
    private static func computeGroups(_ sources: [Source]) -> [MonthGroup] {
        let withDate = sources.compactMap { src -> (Source, Date)? in
            guard let cs = src.createdAt, cs > 0 else { return nil }
            return (src, Date(timeIntervalSince1970: TimeInterval(cs)))
        }
        let undated = sources.filter { ($0.createdAt ?? 0) <= 0 }

        let cal = Calendar.current
        var monthBuckets: [String: [(Source, Date)]] = [:]
        var monthDates: [String: Date] = [:]
        for (src, date) in withDate {
            let comps = cal.dateComponents([.year, .month], from: date)
            let key = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            monthBuckets[key, default: []].append((src, date))
            if let monthStart = cal.date(from: comps) { monthDates[key] = monthStart }
        }

        var result: [MonthGroup] = []
        for key in monthBuckets.keys.sorted(by: >) {
            let items = monthBuckets[key] ?? []
            var dayBuckets: [String: [Source]] = [:]
            var dayDates: [String: Date] = [:]
            for (src, date) in items {
                let comps = cal.dateComponents([.year, .month, .day], from: date)
                let dKey = String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
                dayBuckets[dKey, default: []].append(src)
                if let dayStart = cal.date(from: comps) { dayDates[dKey] = dayStart }
            }
            let days = dayBuckets.keys.sorted(by: >).map { dk in
                DayGroup(id: dk, date: dayDates[dk] ?? Date.distantPast, sources: dayBuckets[dk] ?? [])
            }
            result.append(MonthGroup(id: key, date: monthDates[key] ?? Date.distantPast, days: days))
        }
        if !undated.isEmpty {
            result.append(
                MonthGroup(
                    id: "unknown",
                    date: Date.distantPast,
                    days: [DayGroup(id: "unknown", date: Date.distantPast, sources: undated)]
                )
            )
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                if sources.isEmpty && clips.isEmpty {
                    Text("No footage to browse yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(20)
                }
                ForEach(groups) { month in
                    Section(header: monthHeader(month: month)) {
                        if !collapsedMonths.contains(month.id) {
                            ForEach(month.days) { day in
                                daySection(day: day, monthKey: month.id)
                            }
                        }
                    }
                }
                if !clips.isEmpty {
                    Section {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(clips) { clip in
                                ClipCardView(clip: clip,
                                             isSelected: clip.id.map { appState.selectedClipIDs.contains($0) } ?? false,
                                             onSelect: {
                                                 if let id = clip.id { appState.selectedClipIDs = [id] }
                                                 appState.inspectorVisible = true
                                             },
                                             onOpenInPlayer: { appState.openClip(clip) })
                            }
                        }
                    } header: {
                        Text("Saved clips · \(clips.count)")
                            .font(.headline).foregroundStyle(Theme.textPrimary)
                            .padding(.vertical, 8)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .onAppear { recompute() }
        // Key on a content signature that folds in each source's date, not just
        // the count: the date backfill re-buckets the calendar without adding or
        // removing any rows, so a count-only trigger would miss it.
        .onChange(of: sourcesSignature) { _, _ in recompute() }
    }

    /// Cheap fingerprint of the source set that changes when ids OR recording
    /// dates change — drives recompute precisely when grouping would differ.
    private var sourcesSignature: Int {
        var hasher = Hasher()
        hasher.combine(sources.count)
        for s in sources {
            hasher.combine(s.id)
            hasher.combine(s.createdAt)
            hasher.combine(s.path)
            hasher.combine(s.hash)
            hasher.combine(s.online)
            hasher.combine(s.durationMs)
            hasher.combine(s.fps)
            hasher.combine(s.thumbPath)
        }
        return hasher.finalize()
    }

    private func recompute() {
        let new = Self.computeGroups(sources)
        let structureChanged = new.map(\.id) != groups.map(\.id)
        groups = new
        if !didApplyDefaults || structureChanged {
            applyDefaults()
            didApplyDefaults = true
        }
    }

    /// Most recent month open, older months collapsed; the latest couple of
    /// shoot days expanded, everything older compacted.
    private func applyDefaults() {
        collapsedMonths = Set(groups.dropFirst().map(\.id))
        // groups are month-descending and each month's days are day-descending,
        // so the first N flattened days are the most recent shoots overall.
        let recent = groups.flatMap { $0.days }.prefix(Self.autoExpandRecentDays).map(\.id)
        expandedDays = Set(recent)
    }

    @ViewBuilder
    private func monthHeader(month: MonthGroup) -> some View {
        let isCollapsed = collapsedMonths.contains(month.id)
        Button {
            if isCollapsed { collapsedMonths.remove(month.id) }
            else { collapsedMonths.insert(month.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Text(month.id == "unknown" ? "No recording date" : Self.monthFormatter.string(from: month.date))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(month.totalCount)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Theme.surface, in: Capsule())
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Theme.bg)
    }

    @ViewBuilder
    private func daySection(day: DayGroup, monthKey: String) -> some View {
        let isExpanded = expandedDays.contains(day.id)
        VStack(alignment: .leading, spacing: 8) {
            dayHeader(day: day, isExpanded: isExpanded)
            if isExpanded {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(day.sources) { source in
                        // Single click opens the source in the player — the
                        // whole point of browsing by date is to jump straight
                        // in and start clipping.
                        SourceCardView(source: source) {
                            appState.selectedClipIDs = []
                            appState.playerSourceID = source.id
                            appState.playerInMs = nil
                            appState.playerOutMs = nil
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.bottom, isExpanded ? 8 : 0)
    }

    /// Day header doubles as the expand/collapse control. When collapsed it
    /// reads as a compact, tappable summary chip (date · count · duration).
    @ViewBuilder
    private func dayHeader(day: DayGroup, isExpanded: Bool) -> some View {
        let totalMs = FrameMath.totalDuration(day.sources.map { $0.durationMs ?? 0 })
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                if isExpanded { expandedDays.remove(day.id) }
                else { expandedDays.insert(day.id) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 12)
                Text(day.id == "unknown" ? "Unknown day" : Self.dayFormatter.string(from: day.date))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isExpanded ? Theme.textPrimary : Theme.textSecondary)
                Text("\(day.sources.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if totalMs > 0 {
                    Text(formatTotal(totalMs))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, isExpanded ? 4 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.r1)
                    .fill(isExpanded ? Color.clear : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.r1)
                    .strokeBorder(isExpanded ? Color.clear : Theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formatTotal(_ ms: Int64) -> String {
        let totalSec = Int(ms / 1000)
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        if totalSec < 60 { return "\(totalSec)s" }
        if h > 0 { return "\(h)h \(m)m" }
        return String(format: "%dm", m)
    }
}
