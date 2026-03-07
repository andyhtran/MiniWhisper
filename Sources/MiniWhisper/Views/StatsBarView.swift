import SwiftUI

struct StatsBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let store = appState.analyticsStore
        HStack(spacing: 6) {
            StatCard(label: "Recordings", value: store.formattedRecordings)
            StatCard(label: "Duration", value: store.formattedSpeakingTime)
            StatCard(label: "Words", value: store.formattedWords)
            StatCard(label: "Avg WPM", value: "\(store.averageWPM)")
        }
    }
}

private struct StatCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.3)

            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.08))
        )
    }
}
