import SwiftUI

struct ToastStack: View {
    let toasts: [Toast]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(toasts) { toast in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: toast.level))
                    Text(toast.message)
                    if let label = toast.actionLabel {
                        Button(label) { AppState.shared.runToastAction(toast.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.leading, 2)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .background(Theme.bgRaised.opacity(0.9), in: Capsule())
                .overlay(Capsule().strokeBorder(color(for: toast.level).opacity(0.45), lineWidth: 1))
                .foregroundStyle(color(for: toast.level))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(accessibilityPrefix(for: toast.level)): \(toast.message)"))
                .accessibilityAddTraits(.isStaticText)
                // Tap to dismiss; cancels the auto-dismiss task in AppState
                // so we don't leak a pending sleep.
                .onTapGesture { AppState.shared.dismissToast(toast.id) }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toasts)
    }

    private func icon(for level: ToastLevel) -> String {
        switch level {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func color(for level: ToastLevel) -> Color {
        switch level {
        case .info: return Theme.textSecondary
        case .success: return Theme.success
        case .warning: return .orange
        case .error: return Theme.danger
        }
    }

    private func accessibilityPrefix(for level: ToastLevel) -> String {
        switch level {
        case .info: return "Info"
        case .success: return "Success"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }
}
