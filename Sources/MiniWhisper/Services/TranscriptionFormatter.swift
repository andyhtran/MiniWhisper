import Foundation

/// Single entry point for all post-transcription text processing. Wraps
/// Spoken Symbols, replacement rules, capitalization, auto-paragraph, and
/// trailing-punctuation stripping into one ordered pipeline so every
/// consumer sees the same canonical output.
///
/// The pipeline splits into two phases — `applyReplacements` (Spoken
/// Symbols + user rules) and `applyFormatting` (casing + paragraph +
/// trailing-punctuation strip + trailing space) — so the auto-cleanup
/// path can run replacements on the raw transcript, then route the
/// LLM-cleaned output through formatting. `format` composes both for
/// non-cleanup callers.
enum TranscriptionFormatter {
    struct Options: Sendable {
        let replacementRules: [ReplacementRule]
        let capitalization: CapitalizationStyle
        let autoParagraph: Bool
        let dropTrailingPunctuation: Bool
        let spokenSymbolsEnabled: Bool
        let appendTrailingSpace: Bool
    }

    static func format(_ text: String, options: Options) -> String {
        applyFormatting(to: applyReplacements(to: text, options: options), options: options)
    }

    /// Phase 1: deterministic find/replace (Spoken Symbols, then user
    /// rules). Runs before auto-cleanup so the user's explicit rules
    /// shape what the LLM sees rather than what it returns.
    static func applyReplacements(to text: String, options: Options) -> String {
        var result = text

        if options.spokenSymbolsEnabled {
            result = ReplacementProcessor(rules: SpokenSymbols.rules).apply(to: result)
        }

        if !options.replacementRules.isEmpty {
            let processor = ReplacementProcessor(rules: options.replacementRules)
            result = processor.apply(to: result)
        }

        return result
    }

    /// Phase 2: cosmetic transforms (casing, paragraphs, trailing
    /// punctuation, trailing space). Runs last so the LLM's polish
    /// gets the final formatting pass — and so trailing-punctuation
    /// strip also cleans up any terminal `.` / `!` / `?` an earlier
    /// step or the LLM introduced.
    static func applyFormatting(to text: String, options: Options) -> String {
        var result = text

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

        // Trailing-space step runs last so it survives every other
        // transform. Skipped when the result is empty (a space-only
        // paste is just noise) or already ends in whitespace (the
        // earlier steps occasionally leave a newline; doubling up
        // would push the user's cursor onto a fresh line).
        if options.appendTrailingSpace,
           let last = result.last,
           !last.isWhitespace
        {
            result.append(" ")
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
