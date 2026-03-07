import SwiftUI

enum ToastType {
    case error
    case warning

    var icon: String {
        switch self {
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .error: return .red
        case .warning: return .orange
        }
    }
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let type: ToastType
    let title: String
    var message: String?

    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool {
        lhs.id == rhs.id
    }
}

struct ToastView: View {
    let toast: ToastMessage
    var onDismiss: (() -> Void)?
    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.type.icon)
                .foregroundColor(toast.type.color)
                .font(.system(size: 18))

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.system(size: 13, weight: .medium))

                if let message = toast.message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if toast.type == .error {
                Button {
                    onDismiss?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : -10)
        .onAppear {
            withAnimation(.spring(duration: 0.3, bounce: 0.3)) {
                isVisible = true
            }

            let delay: TimeInterval = toast.type == .error ? 5 : 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeOut(duration: 0.2)) {
                    isVisible = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    onDismiss?()
                }
            }
        }
    }
}
