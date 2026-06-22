import SwiftUI

/// Tiny `info.circle` icon that shows a tooltip popover the instant the
/// cursor enters it. Replaces SwiftUI's `.help()` modifier where the
/// ~2-second NSToolTip delay feels sluggish for short hint text.
///
/// Drop next to a label inside an `HStack(spacing: 4)`:
///
///     HStack(spacing: 4) {
///         Text("Trailing space")
///         InfoBadge(text: "Append a space after each pasted transcription …")
///         Spacer()
///         Toggle(…)
///     }
struct InfoBadge: View {
    let text: String
    @State private var isShown = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .onHover { hovering in
                isShown = hovering
            }
            .popover(isPresented: $isShown, arrowEdge: .top) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 220)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }
}

struct InfoLabel: View {
    let title: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            InfoBadge(text: text)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
