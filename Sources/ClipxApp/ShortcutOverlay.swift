import SwiftUI

/// Press ⌘? anywhere in the app to bring up this overlay. Tap outside or press
/// Esc to dismiss. Other modifier-key presses are forwarded back to the app so
/// shortcuts like ⌘Q still work while the overlay is visible.
struct ShortcutOverlay: View {
    @Binding var visible: Bool

    private let groups: [(title: String, items: [(String, String)])] = [
        ("Marking", [
            ("I", "Mark in point"),
            ("O", "Mark out point"),
            ("S", "Save range as clip"),
            ("3 / 4 / 5", "Rate selected clip(s) (menu only)")
        ]),
        ("Playback", [
            ("␣ or K", "Play / pause"),
            ("←  / →", "Step one frame"),
            ("⇧← / ⇧→", "Jump ±5 seconds"),
            ("J / L", "Jump ±5 seconds (industry-standard transport)")
        ]),
        ("Navigation", [
            ("⌘K", "Command palette"),
            ("⌘F", "Focus search"),
            ("⌘O", "Add folder"),
            ("⌥⌘I", "Toggle Inspector"),
            ("Esc", "Back to Library (from Player)"),
            ("⌘?", "This help overlay")
        ]),
        ("Export", [
            ("⇧⌘R", "Export selected as Reels"),
            ("via Export menu", "All other presets, FCPXML, Obsidian sidecars")
        ])
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
                .onTapGesture { visible = false }
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: "command").foregroundStyle(Theme.textSecondary)
                    Text("Keyboard shortcuts")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button { visible = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(group.title).clipxSectionLabel()
                        ForEach(group.items, id: \.0) { item in
                            HStack(spacing: 12) {
                                Text(item.0)
                                    .clipxKeycap()
                                    .frame(width: 110, alignment: .leading)
                                Text(item.1).foregroundStyle(Theme.textSecondary)
                                Spacer()
                            }
                        }
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    Text("Esc").clipxKeycap()
                    Text("to dismiss").font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(28)
            .frame(width: 580, height: 600)
            .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.r3))
            .overlay(RoundedRectangle(cornerRadius: Theme.r3).strokeBorder(Theme.borderStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        }
        // Only consume non-modified keys; let ⌘Q etc. through so the user can
        // always quit / switch even while the overlay is up.
        .onKeyPress(.escape) {
            visible = false
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            if press.modifiers.isEmpty {
                visible = false
                return .handled
            }
            return .ignored
        }
    }
}
