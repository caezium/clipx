import SwiftUI

/// Stint's zinc surface ladder and off-white actions. Navigation and metadata
/// stay neutral; blue belongs to the timeline, and status colors signal outcomes.
enum Theme {

    // MARK: Surfaces (designed for a dark color scheme)

    static let bg = color(0x09090B)
    static let bgRaised = color(0x111113)
    static let panel = color(0x212124)
    static let surface = color(0x18181B)
    static let field = color(0x19191C)
    static let surfaceHover = color(0x27272A)
    static let surfaceActive = color(0x323235)

    // MARK: Lines
    static let border = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.18)

    // MARK: Text
    static let textPrimary = color(0xFAFAFA)
    static let textSecondary = color(0xA1A1AA)
    static let textTertiary = color(0x85858F)

    // MARK: Accent + semantics
    static let accent = textPrimary
    static let accentSoft = Color.white.opacity(0.09)
    static let timeline = color(0x8BA8D6)
    static let success = color(0x8BBC9C)
    static let warning = color(0xD6B47B)
    static let danger = color(0xE28C8C)
    static let star = textSecondary

    // MARK: Radii
    static let r1: CGFloat = 6
    static let r2: CGFloat = 8
    static let r3: CGFloat = 12
    static let r4: CGFloat = 24

    /// Blue→white scrubber gradient — the visual signature borrowed from stint.
    static let scrubber = LinearGradient(
        colors: [timeline, Color.white],
        startPoint: .leading, endPoint: .trailing
    )

    /// Distinctive serif-italic wordmark, à la stint's EB Garamond.
    static func wordmark(size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .serif).italic()
    }

    /// User-assigned labels keep their hue, with the same palette in every view.
    static func labelColor(_ value: Int) -> Color {
        switch value {
        case 1: return color(0xD18D8D)
        case 2: return color(0xD5AA82)
        case 3: return color(0xD2C184)
        case 4: return success
        case 5: return timeline
        case 6: return color(0xB29BCB)
        default: return textTertiary
        }
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xff) / 255,
              green: Double((hex >> 8) & 0xff) / 255,
              blue: Double(hex & 0xff) / 255)
    }
}

// MARK: - Pill buttons

/// Rounded pill button. `.primary` is a light fill on dark (high-contrast CTA);
/// `.ghost` only gains a surface on hover, keeping secondary actions quiet.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, ghost, accent, danger }
    var kind: Kind = .ghost
    var compact: Bool = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, compact ? 12 : 16)
            .frame(minHeight: compact ? 28 : 32)
            .foregroundStyle(fg)
            .background(bg(pressed: configuration.isPressed), in: Capsule())
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            // Subtle press-in so every button feels physical (feel-better).
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var fg: Color {
        switch kind {
        case .primary: return Theme.bg
        case .ghost:   return hovering ? Theme.textPrimary : Theme.textSecondary
        case .accent:  return Theme.bg
        case .danger:  return Theme.danger
        }
    }
    private func bg(pressed: Bool) -> Color {
        switch kind {
        case .primary: return Color(white: hovering ? 0.88 : 0.97)
        case .ghost:   return hovering ? Theme.surfaceHover : .clear
        case .accent:  return Theme.accent.opacity(hovering ? 0.95 : 0.85)
        case .danger:  return hovering ? Theme.danger.opacity(0.18) : .clear
        }
    }
    private var stroke: Color {
        switch kind {
        case .primary, .accent: return .clear
        case .ghost:  return .clear
        case .danger: return Theme.danger.opacity(0.4)
        }
    }
}

// MARK: - Icon button

/// Small circular icon button with a subtle hover wash. Apply to a
/// `Button { … } label: { Image(systemName:) }.buttonStyle(.plain)`.
struct IconButtonChrome: ViewModifier {
    var size: CGFloat = 30
    var active: Bool = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .frame(width: size, height: size)
            .foregroundStyle(active ? Theme.accent : (hovering ? Theme.textPrimary : Theme.textSecondary))
            .background(
                Circle().fill(hovering || active ? Theme.surfaceHover : .clear)
            )
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    /// A single elevated workspace surface, rather than a border around every row.
    func clipxPanel() -> some View {
        self
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.r4))
            .clipShape(RoundedRectangle(cornerRadius: Theme.r4))
            .overlay(RoundedRectangle(cornerRadius: Theme.r4).strokeBorder(Theme.border, lineWidth: 1))
    }

    func clipxIconButton(size: CGFloat = 30, active: Bool = false) -> some View {
        modifier(IconButtonChrome(size: size, active: active))
    }

    /// Neutral card surface; selection changes its outline, not its hue.
    func clipxCard(radius: CGFloat = Theme.r3, selected: Bool = false) -> some View {
        self
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(selected ? Theme.textSecondary : Theme.border,
                                  lineWidth: selected ? 1.5 : 1)
            )
    }

    /// Compact metadata controls share a lozenge shape and neutral selection.
    func clipxChip(selected: Bool = false, accentColor: Color = Theme.accent) -> some View {
        self
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .foregroundStyle(selected ? accentColor : Theme.textSecondary)
            .background(selected ? accentColor.opacity(0.10) : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.r1))
            .overlay(RoundedRectangle(cornerRadius: Theme.r1)
                .strokeBorder(selected ? accentColor.opacity(0.22) : Theme.border, lineWidth: 1))
    }

    /// Shared surface for text fields and menu pickers; callers own their focus.
    func clipxInputField() -> some View {
        self
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 11).padding(.vertical, 10)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.r2))
            .overlay(RoundedRectangle(cornerRadius: Theme.r2)
                .strokeBorder(Theme.border, lineWidth: 1))
    }

    /// Raycast-style keycap glyph for keyboard shortcuts (e.g. ⌘K, Esc):
    /// monospaced, surface-ladder fill, hairline edge, tight 4px radius.
    func clipxKeycap() -> some View {
        self
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.surfaceActive, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 1))
    }

    /// A thin inset hairline + rounded clip for media tiles (thumbnails,
    /// filmstrips) so they separate from the near-black canvas instead of
    /// floating into the surrounding canvas.
    func clipxMediaEdge(radius: CGFloat = Theme.r1) -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }

    /// Sentence-case labels use one readable size across navigation and forms.
    func clipxSectionLabel() -> some View {
        self
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
    }
}

/// Hover-reactive chip used as a tappable toggle (e.g. quick tags). A `Button`
/// already conveys the tap; this is just consistent styling.
struct ClipxToggleChip: View {
    let label: String
    let selected: Bool
    var accentColor: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).clipxChip(selected: selected, accentColor: accentColor)
        }
        .buttonStyle(.plain)
    }
}

extension ToolbarContent {
    /// Keep the breadcrumb and actions free of an extra capsule on macOS 26.
    /// Earlier systems retain their standard, ungrouped toolbar presentation.
    @ToolbarContentBuilder
    func clipxToolbarChrome() -> some ToolbarContent {
        if #available(macOS 26, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
