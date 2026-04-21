import Foundation

/// Single entry point for all post-transcription text processing. Wraps
/// replacement rules, capitalization, auto-paragraph, and trailing-punctuation
/// stripping into one ordered pipeline so every consumer sees the same
/// canonical output.
///
/// Pipeline order is deliberate:
/// 1. Replacements run on raw text (content layer — *what* the text says).
/// 2. Casing is adjusted (style layer — *how* it looks).
/// 3. Paragraph breaks are inserted.
/// 4. Trailing sentence punctuation is stripped last so it also cleans up
///    any terminal `.` / `!` / `?` introduced by a replacement rule.
enum TranscriptionFormatter {
    struct Options: Sendable {
        let replacementRules: [ReplacementRule]
        let capitalization: CapitalizationStyle
        let autoParagraph: Bool
        let dropTrailingPunctuation: Bool
    }

    static func format(_ text: String, options: Options) -> String {
        var result = text

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
