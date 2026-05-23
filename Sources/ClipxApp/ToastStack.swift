import SwiftUI

struct ToastStack: View {
    let toasts: [Toast]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(toasts) { toast in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: toast.level))
                    Text(toast.message)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(color(for: toast.level).opacity(0.4)))
                .foregroundStyle(color(for: toast.level))
                .transition(.move(edge: .top).combined(with: .opacity))
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
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
