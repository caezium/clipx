import SwiftUI

/// Browse sources grouped by their recording date (NOT import date). Renders
/// a vertical timeline: most recent month at the top, expandable day sections
/// inside. Designed for the "I shot this on the karting weekend in May"
/// workflow where you remember a date but not a filename.
struct CalendarBrowseView: View {
    let sources: [Source]
    @EnvironmentObject private var appState: AppState
    @State private var collapsedMonths: Set<String> = []
    /// Memoized group buckets. The computation is O(N log N) over the sources
    /// array, and was previously re-run on every body invalidation. Now it
    /// runs only when `sources` actually changes.
    @State private var groups: [MonthGroup] = []

    // DateFormatter is expensive to allocate; keep one static.
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 10)]

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
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                if sources.isEmpty {
                    Text("No sources to browse yet.")
                        .foregroundStyle(.secondary)
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
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .onAppear { groups = Self.computeGroups(sources) }
        // Re-group only when the source set actually changes — count is a
        // cheap-but-not-perfect proxy; combined with libraryRevision via
        // LibraryView's reload this catches add/remove flows.
        .onChange(of: sources.count) { _, _ in groups = Self.computeGroups(sources) }
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
                    .font(.caption)
                Text(month.id == "unknown" ? "No recording date" : Self.monthFormatter.string(from: month.date))
                    .font(.title3.weight(.semibold))
                Text("\(month.totalCount)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
    }

    @ViewBuilder
    private func daySection(day: DayGroup, monthKey: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(day.id == "unknown" ? "Unknown day" : Self.dayFormatter.string(from: day.date))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("\(day.sources.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                let totalMs = day.sources.reduce(Int64(0)) { $0 + ($1.durationMs ?? 0) }
                if totalMs > 0 {
                    Text(formatTotal(totalMs))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(day.sources) { source in
                    SourceCardView(source: source)
                        .onTapGesture(count: 2) {
                            appState.selectedClipIDs = []
                            appState.playerSourceID = source.id
                            appState.playerInMs = nil
                            appState.playerOutMs = nil
                        }
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func formatTotal(_ ms: Int64) -> String {
        let totalSec = Int(ms / 1000)
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        if h > 0 { return String(format: "%dh %dm", h, m) }
        return String(format: "%dm", m)
    }
}
