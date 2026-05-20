import Foundation

/// Single entry point for all post-transcription text processing. Wraps
/// Spoken Symbols, replacement rules, capitalization, auto-paragraph, and
/// trailing-punctuation stripping into one ordered pipeline so every
/// consumer sees the same canonical output.
///
/// The pipeline splits into two phases: `applyReplacements` runs Spoken
/// Symbols + ordinary user rules before auto-cleanup, then `applyFormatting`
/// applies style transforms and exact-case replacements after any LLM pass.
/// `format` composes both for non-cleanup callers.
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

    /// Phase 1: deterministic find/replace (Spoken Symbols, then ordinary
    /// user rules). Runs before auto-cleanup so non-case-protected rules can
    /// shape what the LLM sees rather than what it returns.
    static func applyReplacements(to text: String, options: Options) -> String {
        var result = text

        if options.spokenSymbolsEnabled {
            result = ReplacementProcessor(rules: SpokenSymbols.rules).apply(to: result)
        }

        let ordinaryRules = options.replacementRules.filter { !$0.preserveCase }
        if !ordinaryRules.isEmpty {
            let processor = ReplacementProcessor(rules: ordinaryRules)
            result = processor.apply(to: result)
        }

        return result
    }

    /// Phase 2: cosmetic transforms plus exact-case replacements. Exact-case
    /// rules run after capitalization so declared names like `MiniWhisper`
    /// survive Casual lowercase and sentence capitalization.
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

        let exactCaseRules = options.replacementRules.filter(\.preserveCase)
        if !exactCaseRules.isEmpty {
            let processor = ReplacementProcessor(rules: exactCaseRules)
            result = processor.apply(to: result)
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
