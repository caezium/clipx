import SwiftUI

struct ClipListView: View {
    let sources: [Source]
    let clips: [Clip]

    var body: some View {
        Table(clips) {
            TableColumn("Name") { Text($0.name ?? "Untitled") }
            TableColumn("Duration") { Text(formatDuration($0.durationMs)) }
            TableColumn("Rating") { Text(String(repeating: "★", count: $0.rating)) }
            TableColumn("Mood") { Text($0.mood ?? "") }
            TableColumn("Shot") { Text($0.shotType ?? "") }
        }
    }

    private func formatDuration(_ ms: Int64) -> String {
        let totalSec = Int(ms / 1000)
        let m = totalSec / 60, s = totalSec % 60
        return String(format: "%d:%02d", m, s)
    }
}
