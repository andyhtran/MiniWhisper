import Foundation

/// Display-facing grouping of `SpokenSymbols.rules` for the in-app
/// "supported symbols" list. Built from the live rules array at runtime so
/// the list can never drift from what the replacement engine ships.
enum SpokenSymbolsCatalog {

    struct Entry: Identifiable {
        /// Spoken variants that produce `output`, stripped of the padding
        /// spaces and pause-commas the matcher needs, in rule order.
        let phrases: [String]
        let output: String
        /// True when the phrase is space-padded on both sides, so the rule
        /// joins the surrounding words instead of standing alone.
        let joinsWords: Bool

        var id: String { output }
    }

    /// `allCases` order is the display order.
    enum Category: CaseIterable {
        case pairedDelimiters
        case symbols
        case languageNames
        case fileExtensions

        var title: String {
            switch self {
            case .pairedDelimiters: return "Paired delimiters"
            case .symbols: return "Symbols"
            case .languageNames: return "Language names"
            case .fileExtensions: return "File extensions"
            }
        }
    }

    struct Exclusion: Identifiable {
        let phrase: String
        let symbol: String
        let reason: String

        var id: String { phrase }
    }

    /// Deliberately unsupported phrases, listed so users can tell "not
    /// supported" apart from "broken". A test asserts none of these ever
    /// ships as a rule — update both together.
    static let exclusions: [Exclusion] = [
        Exclusion(
            phrase: "dash",
            symbol: "-",
            reason: "Say \u{201C}hyphen\u{201D} instead."
        ),
        Exclusion(
            phrase: "caret",
            symbol: "^",
            reason: "Speech-to-text confuses \u{201C}caret\u{201D} and \u{201C}carrot\u{201D} in both directions."
        ),
    ]

    static func entries(in category: Category) -> [Entry] {
        grouped[category] ?? []
    }

    /// Strips the matcher-required padding (boundary spaces, pause-comma
    /// variants) down to the bare spoken phrase.
    static func displayPhrase(for find: String) -> String {
        find.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }

    private static let grouped: [Category: [Entry]] = {
        var outputsInOrder: [String] = []
        var phrasesByOutput: [String: [String]] = [:]
        var joinsByOutput: [String: Bool] = [:]

        for rule in SpokenSymbols.rules {
            let phrase = displayPhrase(for: rule.find)
            if phrasesByOutput[rule.replace] == nil {
                outputsInOrder.append(rule.replace)
            }
            var phrases = phrasesByOutput[rule.replace, default: []]
            if !phrases.contains(phrase) {
                phrases.append(phrase)
            }
            phrasesByOutput[rule.replace] = phrases

            let padded = rule.find.hasPrefix(" ") && rule.find.hasSuffix(" ")
            joinsByOutput[rule.replace] = joinsByOutput[rule.replace, default: false] || padded
        }

        var result: [Category: [Entry]] = [:]
        for output in outputsInOrder {
            let entry = Entry(
                phrases: phrasesByOutput[output] ?? [],
                output: output,
                joinsWords: joinsByOutput[output] ?? false
            )
            result[category(for: output), default: []].append(entry)
        }
        return result
    }()

    private static func category(for output: String) -> Category {
        if output.hasPrefix(".") { return .fileExtensions }
        if ["(", ")", "[", "]", "{", "}"].contains(output) { return .pairedDelimiters }
        if output.contains(where: { $0.isLetter || $0.isNumber }) { return .languageNames }
        return .symbols
    }
}
