import Foundation
import SwiftUI

struct AppVersionInfo {
    let shortVersion: String

    static var current: AppVersionInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let shortVersion = info["CFBundleShortVersionString"] as? String

        return AppVersionInfo(
            shortVersion: shortVersion?.nilIfBlank ?? "Development"
        )
    }

    var displayString: String {
        shortVersion
    }
}

struct AppVersionFooter: View {
    private let version = AppVersionInfo.current

    var body: some View {
        HStack {
            Text("Version")
            Spacer()
            Text(version.displayString)
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Version \(version.displayString)")
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
