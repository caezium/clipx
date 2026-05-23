import SwiftUI

/// Press ? anywhere in the app to bring up this overlay. Anything dismisses it.
struct ShortcutOverlay: View {
    @Binding var visible: Bool

    private let groups: [(title: String, items: [(String, String)])] = [
        ("Marking", [
            ("I", "Mark in point"),
            ("O", "Mark out point"),
            ("S", "Save range as clip"),
            ("1–5", "Rate selected clip(s)")
        ]),
        ("Playback", [
            ("␣", "Play / pause"),
            ("←", "Step one frame back"),
            ("→", "Step one frame forward")
        ]),
        ("Navigation", [
            ("⌘K", "Command palette"),
            ("⌘F", "Focus search"),
            ("⌘O", "Add folder"),
            ("?", "This help overlay")
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
                    Image(systemName: "command")
                    Text("Keyboard shortcuts").font(.title2.bold())
                    Spacer()
                    Button { visible = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title).font(.headline).foregroundStyle(.secondary)
                        ForEach(group.items, id: \.0) { item in
                            HStack(spacing: 12) {
                                Text(item.0)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                                    .frame(minWidth: 80, alignment: .leading)
                                Text(item.1).foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                    }
                }
                Spacer()
                Text("Press anywhere to dismiss")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(width: 540, height: 540)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 30)
        }
        .onKeyPress { _ in
            visible = false
            return .handled
        }
    }
}
