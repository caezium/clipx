import SwiftUI

/// Browse sources grouped by their recording date (NOT import date). Renders
/// a vertical timeline: most recent month at the top, expandable day sections
/// inside. Designed for the "I shot this on the karting weekend in May"
/// workflow where you remember a date but not a filename.
struct CalendarBrowseView: View {
    let sources: [Source]
    @EnvironmentObject private var appState: AppState
    @State private var collapsedMonths: Set<String> = []

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 10)]
    private let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()

    /// Groups (monthKey, monthDate, [(dayKey, dayDate, [Source])]) in
    /// chronological-descending order.
    private var grouped: [(monthKey: String, monthDate: Date, days: [(dayKey: String, dayDate: Date, sources: [Source])])] {
        // Sources without a created_at fall under "Unknown date" at the end.
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

        var result: [(String, Date, [(String, Date, [Source])])] = []
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
                (dk, dayDates[dk] ?? Date.distantPast, dayBuckets[dk] ?? [])
            }
            result.append((key, monthDates[key] ?? Date.distantPast, days))
        }
        if !undated.isEmpty {
            result.append(("unknown", Date.distantPast, [("unknown", Date.distantPast, undated)]))
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
                ForEach(grouped, id: \.monthKey) { month in
                    Section(header: monthHeader(month: month)) {
                        if !collapsedMonths.contains(month.monthKey) {
                            ForEach(month.days, id: \.dayKey) { day in
                                daySection(day: day, monthKey: month.monthKey)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func monthHeader(month: (monthKey: String, monthDate: Date, days: [(dayKey: String, dayDate: Date, sources: [Source])])) -> some View {
        let isCollapsed = collapsedMonths.contains(month.monthKey)
        let totalSources = month.days.reduce(0) { $0 + $1.sources.count }
        Button {
            if isCollapsed { collapsedMonths.remove(month.monthKey) }
            else { collapsedMonths.insert(month.monthKey) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption)
                Text(month.monthKey == "unknown" ? "No recording date" : monthFormatter.string(from: month.monthDate))
                    .font(.title3.weight(.semibold))
                Text("\(totalSources)")
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
    private func daySection(day: (dayKey: String, dayDate: Date, sources: [Source]), monthKey: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(day.dayKey == "unknown" ? "Unknown day" : dayFormatter.string(from: day.dayDate))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("\(day.sources.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                // Duration total for the day
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
