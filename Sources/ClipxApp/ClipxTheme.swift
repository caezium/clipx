import SwiftUI

/// Clipx design system — a dark, minimal, low-chrome aesthetic in the spirit of
/// Raycast's command-palette UI: a near-black canvas with a faint surface
/// *ladder* (bg → bgRaised → surface → surfaceActive) instead of drop shadows,
/// hairline 1px borders on every edge, tight 6–14px radii, monospaced keycaps
/// for shortcuts, and a single accent (+ success green for in/out marks).
/// Depth comes from the surface ladder and hairlines, never shadows.
/// Everything the UI uses lives here so the look stays consistent everywhere.
enum Theme {

    // MARK: Surfaces (designed for a dark color scheme)

    /// App background — near-black with a faint cool tint.
    static let bg = Color(red: 0.043, green: 0.044, blue: 0.055)
    /// Slightly raised background for the sidebar / bars.
    static let bgRaised = Color(red: 0.072, green: 0.074, blue: 0.088)
    /// Translucent card fill — reads as frosted over `bg`.
    static let surface = Color.white.opacity(0.045)
    static let surfaceHover = Color.white.opacity(0.075)
    static let surfaceActive = Color.white.opacity(0.10)

    // MARK: Lines
    static let border = Color.white.opacity(0.085)
    static let borderStrong = Color.white.opacity(0.16)

    // MARK: Text
    static let textPrimary = Color(white: 0.96)
    static let textSecondary = Color(white: 0.62)
    static let textTertiary = Color(white: 0.42)

    // MARK: Accent + semantics
    /// Single accent — a clean electric blue. Used for selection + the scrubber.
    static let accent = Color(red: 0.40, green: 0.60, blue: 1.0)
    static let accentSoft = Color(red: 0.40, green: 0.60, blue: 1.0).opacity(0.16)
    /// In/out marks, "saved", "good" — the only other color that carries meaning.
    static let success = Color(red: 0.22, green: 0.82, blue: 0.50)
    static let danger = Color(red: 0.96, green: 0.38, blue: 0.40)
    static let star = Color(red: 1.0, green: 0.78, blue: 0.28)

    // MARK: Radii
    static let r1: CGFloat = 6
    static let r2: CGFloat = 10
    static let r3: CGFloat = 14
    static let r4: CGFloat = 20

    /// Blue→white scrubber gradient — the visual signature borrowed from stint.
    static let scrubber = LinearGradient(
        colors: [Color(red: 0.40, green: 0.60, blue: 1.0),
                 Color(red: 0.78, green: 0.85, blue: 1.0),
                 Color.white],
        startPoint: .leading, endPoint: .trailing
    )

    /// Distinctive serif-italic wordmark, à la stint's EB Garamond.
    static func wordmark(size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .serif).italic()
    }
}

// MARK: - Pill buttons

/// Rounded pill button. `.primary` is a light fill on dark (high-contrast CTA);
/// `.ghost` is transparent with a hairline that fills subtly on hover;
/// `.accent` is the blue fill for the main action.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, ghost, accent, danger }
    var kind: Kind = .ghost
    var compact: Bool = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 5 : 7)
            .foregroundStyle(fg)
            .background(bg(pressed: configuration.isPressed), in: Capsule())
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            // Subtle press-in so every button feels physical (feel-better).
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }

    private var fg: Color {
        switch kind {
        case .primary: return Theme.bg
        case .ghost:   return Theme.textPrimary
        case .accent:  return .white
        case .danger:  return Theme.danger
        }
    }
    private func bg(pressed: Bool) -> Color {
        switch kind {
        case .primary: return Color(white: hovering ? 0.88 : 0.97)
        case .ghost:   return hovering ? Theme.surfaceHover : Theme.surface
        case .accent:  return Theme.accent.opacity(hovering ? 0.95 : 0.85)
        case .danger:  return hovering ? Theme.danger.opacity(0.18) : .clear
        }
    }
    private var stroke: Color {
        switch kind {
        case .primary, .accent: return .clear
        case .ghost:  return Theme.border
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
    func clipxIconButton(size: CGFloat = 30, active: Bool = false) -> some View {
        modifier(IconButtonChrome(size: size, active: active))
    }

    /// Card surface: translucent fill, hairline border, no shadow. Selected
    /// cards get an accent ring.
    func clipxCard(radius: CGFloat = Theme.r2, selected: Bool = false) -> some View {
        self
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(selected ? Theme.accent : Theme.border,
                                  lineWidth: selected ? 1.5 : 1)
            )
    }

    /// Borderless pill chip used for tags / attributes / quick toggles.
    func clipxChip(selected: Bool = false, accentColor: Color = Theme.accent) -> some View {
        self
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(selected ? accentColor : Theme.textSecondary)
            .background(selected ? accentColor.opacity(0.16) : Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? accentColor.opacity(0.45) : Theme.border, lineWidth: 1))
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
    /// floating (Raycast puts a hairline on every edge).
    func clipxMediaEdge(radius: CGFloat = Theme.r1) -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }

    /// Section label: tiny, uppercase, tracked-out, muted.
    func clipxSectionLabel() -> some View {
        self
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(Theme.textTertiary)
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
