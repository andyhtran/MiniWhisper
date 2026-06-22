import SwiftUI

struct FormatPopoverView: View {
    // Local mirror so SwiftUI re-renders when the user toggles values.
    // FormattingSettings is a UserDefaults wrapper, not @Observable.
    @State private var capitalization = FormattingSettings.capitalization
    @State private var autoParagraph = FormattingSettings.autoParagraph
    @State private var dropTrailingPunctuation = FormattingSettings.dropTrailingPunctuation
    @State private var spokenSymbolsEnabled = SpokenSymbolsSettings.enabled
    @State private var appendTrailingSpace = FormattingSettings.appendTrailingSpace
    @State private var showSymbolsList = false
    @State private var isHoveringSymbolsInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Formatting")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            HStack {
                Text("Capitalization")
                    .font(.system(size: 13))
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { capitalization },
                        set: {
                            capitalization = $0
                            FormattingSettings.capitalization = $0
                        }
                    )
                ) {
                    ForEach(CapitalizationStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            HStack {
                Text("Auto paragraphs")
                    .font(.system(size: 13))
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { autoParagraph },
                        set: {
                            autoParagraph = $0
                            FormattingSettings.autoParagraph = $0
                        }
                    )
                )
                .toggleStyle(.switch)
                .labelsHidden()
            }

            HStack {
                Text("Drop trailing punctuation")
                    .font(.system(size: 13))
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { dropTrailingPunctuation },
                        set: {
                            dropTrailingPunctuation = $0
                            FormattingSettings.dropTrailingPunctuation = $0
                        }
                    )
                )
                .toggleStyle(.switch)
                .labelsHidden()
            }

            HStack(spacing: 4) {
                Text("Spoken symbols")
                    .font(.system(size: 13))
                // Click-to-open list instead of an InfoBadge: a hover popover
                // and a click popover on the same anchor fight each other.
                Button {
                    showSymbolsList.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(isHoveringSymbolsInfo ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHoveringSymbolsInfo = hovering
                }
                .popover(isPresented: $showSymbolsList, arrowEdge: .trailing) {
                    SpokenSymbolsListView()
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { spokenSymbolsEnabled },
                        set: {
                            spokenSymbolsEnabled = $0
                            SpokenSymbolsSettings.enabled = $0
                        }
                    )
                )
                .toggleStyle(.switch)
                .labelsHidden()
            }

            HStack(spacing: 4) {
                Text("Trailing space")
                    .font(.system(size: 13))
                InfoBadge(text: "Append a space after each pasted transcription so you can keep typing without pressing space first.")
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { appendTrailingSpace },
                        set: {
                            appendTrailingSpace = $0
                            FormattingSettings.appendTrailingSpace = $0
                        }
                    )
                )
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .padding(12)
        .frame(width: 280)
        .onAppear {
            capitalization = FormattingSettings.capitalization
            autoParagraph = FormattingSettings.autoParagraph
            dropTrailingPunctuation = FormattingSettings.dropTrailingPunctuation
            spokenSymbolsEnabled = SpokenSymbolsSettings.enabled
            appendTrailingSpace = FormattingSettings.appendTrailingSpace
        }
    }
}
