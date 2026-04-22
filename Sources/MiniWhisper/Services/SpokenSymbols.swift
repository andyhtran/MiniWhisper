import Foundation

/// Ideal checklist:
/// 1. **Natural-English safety.** The `find` phrase has no common non-symbol
///    meaning in everyday speech. If the phrase regularly appears in casual
///    speech with a different meaning (e.g. "mad dash", "slash of rain",
///    "gas pipe"), it will cause false positives and must be excluded.
/// 2. **STT homophone safety.** The transcriber reliably produces the exact
///    `find` phrase when the symbol is intended, and does not produce it when
///    the user means a homophone. Example failure: `caret` vs `carrot` — STT
///    confuses them in both directions, producing false positives *and* false
///    negatives.
/// When adding a new rule, add BOTH a true-positive and a true-negative test
/// case to `SpokenSymbolsTests.swift`.
enum SpokenSymbols {
    static let rules: [ReplacementRule] = [
        ReplacementRule(find: "open parentheses ", replace: "("),
        ReplacementRule(find: "open parentheses, ", replace: "("),
        ReplacementRule(find: "open parenthesis ", replace: "("),
        ReplacementRule(find: "open parenthesis, ", replace: "("),
        ReplacementRule(find: "open paren ", replace: "("),
        ReplacementRule(find: "open paren, ", replace: "("),
        ReplacementRule(find: " close parentheses", replace: ")"),
        ReplacementRule(find: ", close parentheses", replace: ")"),
        ReplacementRule(find: " close parenthesis", replace: ")"),
        ReplacementRule(find: ", close parenthesis", replace: ")"),
        ReplacementRule(find: " close paren", replace: ")"),
        ReplacementRule(find: ", close paren", replace: ")"),
        ReplacementRule(find: "open bracket ", replace: "["),
        ReplacementRule(find: "open bracket, ", replace: "["),
        ReplacementRule(find: " close bracket", replace: "]"),
        ReplacementRule(find: ", close bracket", replace: "]"),
        ReplacementRule(find: "open brace ", replace: "{"),
        ReplacementRule(find: "open brace, ", replace: "{"),
        ReplacementRule(find: " close brace", replace: "}"),
        ReplacementRule(find: ", close brace", replace: "}"),
        ReplacementRule(find: "dot env", replace: ".env"),
        ReplacementRule(find: "dot git ignore", replace: ".gitignore"),
        ReplacementRule(find: "dot gitignore", replace: ".gitignore"),
        ReplacementRule(find: "dot git", replace: ".git"),
        ReplacementRule(find: "dot js", replace: ".js"),
        ReplacementRule(find: "dot ts", replace: ".ts"),
        ReplacementRule(find: "dot tsx", replace: ".tsx"),
        ReplacementRule(find: "dot jsx", replace: ".jsx"),
        ReplacementRule(find: "dot json", replace: ".json"),
        ReplacementRule(find: "dot yaml", replace: ".yaml"),
        ReplacementRule(find: "dot yml", replace: ".yml"),
        ReplacementRule(find: "dot toml", replace: ".toml"),
        ReplacementRule(find: "dot md", replace: ".md"),
        ReplacementRule(find: "dot py", replace: ".py"),
        ReplacementRule(find: "dot rb", replace: ".rb"),
        ReplacementRule(find: "dot go", replace: ".go"),
        ReplacementRule(find: "dot rs", replace: ".rs"),
        ReplacementRule(find: "dot swift", replace: ".swift"),
        ReplacementRule(find: "dot sh", replace: ".sh"),
        ReplacementRule(find: "dot lock", replace: ".lock"),
        ReplacementRule(find: "dot html", replace: ".html"),
        ReplacementRule(find: "dot css", replace: ".css"),
        ReplacementRule(find: "semicolon", replace: ";"),
        // Space-eating so `foo hyphen bar` → `foo-bar` (kebab-case, CLI
        // flags, URL slugs). `dash` stays excluded — "mad dash" et al.
        ReplacementRule(find: " hyphen ", replace: "-"),
        ReplacementRule(find: "backslash", replace: "\\"),
        ReplacementRule(find: "ampersand", replace: "&"),
        ReplacementRule(find: "backtick", replace: "`"),
        ReplacementRule(find: "back tick", replace: "`"),
        ReplacementRule(find: "tilde", replace: "~"),
        ReplacementRule(find: "tilda", replace: "~"),
        ReplacementRule(find: "c plus plus", replace: "c++"),
        ReplacementRule(find: "c sharp", replace: "C#"),
        ReplacementRule(find: "f sharp", replace: "F#"),
    ]
}
