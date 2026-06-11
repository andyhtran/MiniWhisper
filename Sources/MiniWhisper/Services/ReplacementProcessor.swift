import Foundation

/// Case-insensitive find/replace where each edge of `find` independently
/// gets a `\b` word boundary if that edge is an ASCII word-character: plain
/// words anchor both sides, `c++` anchors only its left, and space-padded
/// rules like `"open bracket "` anchor their word side so they can never
/// fire inside a larger word ("reopen"). Pure non-word-edge rules
/// (` dash `) still match literally. Rules apply longest-`find`-first
/// so specific phrases win over substrings of themselves (`new york times`
/// beats `new york`); stable sort preserves user order on length ties.
struct ReplacementProcessor: Sendable {
    let rules: [ReplacementRule]

    func apply(to text: String) -> String {
        guard !rules.isEmpty else { return text }

        // Longest `find` first — prevents a short rule from eating input a
        // longer rule was meant to claim. Ties keep user order so chains
        // like `a→b` then `b→c` still cascade as written.
        let orderedRules = rules.sorted { $0.find.count > $1.find.count }

        var result = text
        for rule in orderedRules {
            let find = rule.find
            guard rule.enabled, !find.isEmpty else { continue }

            let escapedFind = NSRegularExpression.escapedPattern(for: find)
            let leading = Self.isAsciiWordChar(find.first) ? "\\b" : ""
            let trailing = Self.isAsciiWordChar(find.last) ? "\\b" : ""
            let pattern = leading + escapedFind + trailing

            // `$` and `\` in the replacement must stay literal — user rules
            // aren't regex templates.
            let replacement = NSRegularExpression.escapedTemplate(for: rule.replace)

            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Collapse horizontal whitespace runs left by filler removals
        // (`"a z b"` → `"a  b"`). Newlines preserved so paragraphs survive.
        result = result.replacingOccurrences(
            of: "[ \\t]+",
            with: " ",
            options: .regularExpression
        )

        return result
    }

    private static func isAsciiWordChar(_ c: Character?) -> Bool {
        guard let c, c.isASCII else { return false }
        return c.isLetter || c.isNumber || c == "_"
    }
}
