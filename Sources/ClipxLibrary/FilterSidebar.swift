import SwiftUI

struct FilterSidebar: View {
    @EnvironmentObject private var appState: AppState

    private let moodOptions = ["calm", "dramatic", "energetic", "melancholic", "hopeful", "tense"]
    private let shotOptions = ["close-up", "medium", "wide", "extreme-wide"]
    private let cameraOptions = ["static", "pan", "tilt", "dolly", "handheld", "drone", "gimbal"]
    private let settingOptions = ["indoor", "outdoor", "urban", "nature", "studio"]

    var body: some View {
        DisclosureGroup("Mood") {
            ForEach(moodOptions, id: \.self) { mood in
                ToggleChip(label: mood, isOn: Binding(
                    get: { appState.activeFilters.moods.contains(mood) },
                    set: { isOn in
                        if isOn { appState.activeFilters.moods.insert(mood) }
                        else { appState.activeFilters.moods.remove(mood) }
                    }
                ))
            }
        }
        DisclosureGroup("Shot type") {
            ForEach(shotOptions, id: \.self) { st in
                ToggleChip(label: st, isOn: Binding(
                    get: { appState.activeFilters.shotTypes.contains(st) },
                    set: { isOn in
                        if isOn { appState.activeFilters.shotTypes.insert(st) }
                        else { appState.activeFilters.shotTypes.remove(st) }
                    }
                ))
            }
        }
        DisclosureGroup("Camera") {
            ForEach(cameraOptions, id: \.self) { c in
                ToggleChip(label: c, isOn: Binding(
                    get: { appState.activeFilters.cameraMoves.contains(c) },
                    set: { isOn in
                        if isOn { appState.activeFilters.cameraMoves.insert(c) }
                        else { appState.activeFilters.cameraMoves.remove(c) }
                    }
                ))
            }
        }
        DisclosureGroup("Setting") {
            ForEach(settingOptions, id: \.self) { s in
                ToggleChip(label: s, isOn: Binding(
                    get: { appState.activeFilters.settings.contains(s) },
                    set: { isOn in
                        if isOn { appState.activeFilters.settings.insert(s) }
                        else { appState.activeFilters.settings.remove(s) }
                    }
                ))
            }
        }
        DisclosureGroup("Rating") {
            HStack {
                Text("Min")
                Stepper(value: $appState.activeFilters.minRating, in: 0...5) {
                    Text(String(repeating: "★", count: appState.activeFilters.minRating))
                }
            }
        }
        Toggle("Unused only", isOn: $appState.activeFilters.unusedOnly)
        if appState.activeFilters.isActive {
            Button("Clear filters") { appState.activeFilters = ClipFilters() }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
        }
    }
}

private struct ToggleChip: View {
    let label: String
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                Text(label)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? .primary : .secondary)
    }
}
