import SwiftUI

struct FormatPopoverView: View {
    // Local mirror so SwiftUI re-renders when the user toggles values.
    // FormattingSettings is a UserDefaults wrapper, not @Observable.
    @State private var capitalization = FormattingSettings.capitalization
    @State private var autoParagraph = FormattingSettings.autoParagraph
    @State private var dropTrailingPunctuation = FormattingSettings.dropTrailingPunctuation

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
        }
        .padding(12)
        .frame(width: 280)
        .onAppear {
            capitalization = FormattingSettings.capitalization
            autoParagraph = FormattingSettings.autoParagraph
            dropTrailingPunctuation = FormattingSettings.dropTrailingPunctuation
        }
    }
}
