import Foundation

/// Single entry point for all post-transcription text processing. Wraps
/// Spoken Symbols, replacement rules, capitalization, auto-paragraph, and
/// trailing-punctuation stripping into one ordered pipeline so every
/// consumer sees the same canonical output.
///
/// Pipeline order is deliberate: Spoken Symbols run first so user
/// replacement rules operate on normalized text, then casing, then
/// auto-paragraph, then trailing-punctuation strip (last so it also
/// cleans up any terminal `.` / `!` / `?` a replacement introduced).
enum TranscriptionFormatter {
    struct Options: Sendable {
        let replacementRules: [ReplacementRule]
        let capitalization: CapitalizationStyle
        let autoParagraph: Bool
        let dropTrailingPunctuation: Bool
        let spokenSymbolsEnabled: Bool
    }

    static func format(_ text: String, options: Options) -> String {
        var result = text

        if options.spokenSymbolsEnabled {
            result = ReplacementProcessor(rules: SpokenSymbols.rules).apply(to: result)
        }

        if !options.replacementRules.isEmpty {
            let processor = ReplacementProcessor(rules: options.replacementRules)
            result = processor.apply(to: result)
        }

        switch options.capitalization {
        case .auto:
            result = uppercaseFirstCharacter(result)
        case .casual:
            result = result.lowercased()
        case .off:
            break
        }

        if options.autoParagraph {
            result = TextFormatter.format(result)
        }

        if options.dropTrailingPunctuation {
            result = stripTrailingSentencePunctuation(result)
        }

        return result
    }

    /// Trims trailing whitespace, then consumes any run of `.` / `!` / `?`
    /// at the tail end so `"hello!!!"` collapses to `"hello"`. Interior
    /// punctuation is left alone.
    private static func stripTrailingSentencePunctuation(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, last.isWhitespace {
            result = result.dropLast()
        }
        while let last = result.last, last == "." || last == "!" || last == "?" || last == "," {
            result = result.dropLast()
        }
        return String(result)
    }

    private static func uppercaseFirstCharacter(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
