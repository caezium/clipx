import SwiftUI

/// Filter section rendered as plain expandable rows. Avoids macOS 26's
/// DisclosureGroup which has alignment issues in narrow sidebar columns.
struct FilterSidebar: View {
    @EnvironmentObject private var appState: AppState

    private let moodOptions = ["calm", "dramatic", "energetic", "melancholic", "hopeful", "tense"]
    private let shotOptions = ["close-up", "medium", "wide", "extreme-wide"]
    private let cameraOptions = ["static", "pan", "tilt", "dolly", "handheld", "drone", "gimbal"]
    private let settingOptions = ["indoor", "outdoor", "urban", "nature", "studio"]

    @State private var moodOpen = false
    @State private var shotOpen = false
    @State private var cameraOpen = false
    @State private var settingOpen = false
    @State private var ratingOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            disclosure(title: "Mood", isOpen: $moodOpen) {
                ForEach(moodOptions, id: \.self) { mood in
                    chipRow(label: mood,
                            isOn: appState.activeFilters.moods.contains(mood)) { isOn in
                        if isOn { appState.activeFilters.moods.insert(mood) }
                        else { appState.activeFilters.moods.remove(mood) }
                    }
                }
            }
            disclosure(title: "Shot type", isOpen: $shotOpen) {
                ForEach(shotOptions, id: \.self) { s in
                    chipRow(label: s,
                            isOn: appState.activeFilters.shotTypes.contains(s)) { isOn in
                        if isOn { appState.activeFilters.shotTypes.insert(s) }
                        else { appState.activeFilters.shotTypes.remove(s) }
                    }
                }
            }
            disclosure(title: "Camera", isOpen: $cameraOpen) {
                ForEach(cameraOptions, id: \.self) { c in
                    chipRow(label: c,
                            isOn: appState.activeFilters.cameraMoves.contains(c)) { isOn in
                        if isOn { appState.activeFilters.cameraMoves.insert(c) }
                        else { appState.activeFilters.cameraMoves.remove(c) }
                    }
                }
            }
            disclosure(title: "Setting", isOpen: $settingOpen) {
                ForEach(settingOptions, id: \.self) { s in
                    chipRow(label: s,
                            isOn: appState.activeFilters.settings.contains(s)) { isOn in
                        if isOn { appState.activeFilters.settings.insert(s) }
                        else { appState.activeFilters.settings.remove(s) }
                    }
                }
            }
            disclosure(title: "Rating", isOpen: $ratingOpen) {
                HStack {
                    Stepper(value: $appState.activeFilters.minRating, in: 0...5) {
                        Text("Min \(String(repeating: "★", count: appState.activeFilters.minRating))")
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 6)
            }
            Button { appState.activeFilters.unusedOnly.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: appState.activeFilters.unusedOnly ? "checkmark.square.fill" : "square")
                        .frame(width: 16)
                        .foregroundStyle(appState.activeFilters.unusedOnly ? .primary : .secondary)
                    Text("Unused only").font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Unused only")
            .accessibilityValue(appState.activeFilters.unusedOnly ? "on" : "off")

            if appState.activeFilters.isActive || appState.selectedProjectID != nil || appState.selectedCollectionID != nil {
                Button("Clear filters") {
                    appState.activeFilters = ClipFilters()
                    appState.selectedProjectID = nil
                    appState.selectedCollectionID = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func disclosure<Content: View>(
        title: String,
        isOpen: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // A real Button so it's VoiceOver-actionable with a focus ring and
            // an adequate hit target, not a tap-gesture on a plain row. (#40)
            Button { isOpen.wrappedValue.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 16)
                    Text(title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) filters")
            .accessibilityValue(isOpen.wrappedValue ? "expanded" : "collapsed")
            if isOpen.wrappedValue {
                VStack(alignment: .leading, spacing: 2) {
                    content()
                }
                .padding(.leading, 22)
            }
        }
    }

    @ViewBuilder
    private func chipRow(label: String, isOn: Bool, action: @escaping (Bool) -> Void) -> some View {
        Button { action(!isOn) } label: {
            HStack(spacing: 6) {
                // Pair the color with a check glyph so state isn't conveyed by
                // hue alone. (#40)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.caption2)
                    .frame(width: 12)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Text(label).font(.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isOn ? .primary : .secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "selected" : "not selected")
    }
}
