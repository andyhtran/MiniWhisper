import SwiftUI

/// Scrollable reference list of every spoken-symbol phrase the app supports,
/// plus the deliberate exclusions, generated from `SpokenSymbolsCatalog`.
struct SpokenSymbolsListView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spoken Symbols")
                .font(.system(size: 13, weight: .semibold))
            Text("Phrases converted to symbols while dictating. Matching is case-insensitive.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(SpokenSymbolsCatalog.Category.allCases, id: \.self) { category in
                        section(for: category)
                    }
                    exclusionsSection
                    Text("Anything not listed here isn't converted — add a custom replacement rule instead.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .frame(width: 320, height: 420)
    }

    @ViewBuilder
    private func section(for category: SpokenSymbolsCatalog.Category) -> some View {
        let entries = SpokenSymbolsCatalog.entries(in: category)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                sectionHeader(category.title)
                if category == .fileExtensions {
                    extensionsBlob(entries)
                } else {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
            }
        }
    }

    private func row(_ entry: SpokenSymbolsCatalog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.phrases.joined(separator: ", "))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                if entry.joinsWords, let phrase = entry.phrases.first {
                    Text("joins words: \u{201C}foo \(phrase) bar\u{201D} → foo\(entry.output)bar")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 12)
            Text(entry.output)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }

    /// File extensions get a compact blob instead of one row per rule —
    /// the spoken phrase is always "dot" + the extension, so per-row
    /// phrase/output pairs would just repeat themselves 21 times.
    private func extensionsBlob(_ entries: [SpokenSymbolsCatalog.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Say \u{201C}dot\u{201D} followed by the extension:")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(entries.map(\.output).joined(separator: "  "))
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var exclusionsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionHeader("Not supported")
            ForEach(SpokenSymbolsCatalog.exclusions) { exclusion in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(exclusion.phrase)
                            .font(.system(size: 12))
                        Spacer(minLength: 12)
                        Text(exclusion.symbol)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Text(exclusion.reason)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }
}
