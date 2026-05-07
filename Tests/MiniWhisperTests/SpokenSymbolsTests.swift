import Testing
@testable import MiniWhisper

struct SpokenSymbolsTests {
    @Test(arguments: [
        // Parentheses — grammatical asymmetry on `parentheses`/`parenthesis`
        // is intentional (matches natural dictation).
        ("call foo open parentheses bar close parenthesis", "call foo (bar)"),
        ("open parentheses A close parenthesis and open parentheses B close parenthesis", "(A) and (B)"),

        // STT routinely produces the plural "close parentheses" (and some
        // speakers say "open parenthesis" singular). Both forms must fire.
        ("call foo open parentheses bar close parentheses", "call foo (bar)"),
        ("open parenthesis X close parenthesis", "(X)"),
        ("open parenthesis Y close parentheses", "(Y)"),

        // STT inserts pause-commas mid-phrase. Without comma-variant
        // rules, the comma gets stranded inside the brackets.
        ("call foo open parentheses bar, close parenthesis", "call foo (bar)"),
        ("use open bracket zero, close bracket", "use [zero]"),
        ("declare open brace, x, close brace", "declare {x}"),
        ("open brace, y, close brace", "{y}"),

        // STT splits "gitignore" into "git ignore"; the three-word rule
        // must beat bare "dot git" via longest-first ordering.
        ("open the dot git ignore", "open the .gitignore"),

        // Casual "paren" shorthand. Longest-first ordering ensures the
        // full `parenthesis`/`parentheses` forms still win when present,
        // so these don't cannibalize the longer phrases.
        ("call foo open paren bar close paren", "call foo (bar)"),
        ("open paren A close paren and open paren B close paren", "(A) and (B)"),
        ("open paren, x, close paren", "(x)"),

        // Brackets and braces.
        ("open bracket x close bracket", "[x]"),
        ("open brace y close brace", "{y}"),

        // File extensions. Bare-word `find` relies on `\b` boundaries.
        ("save the dot env file", "save the .env file"),
        ("open the dot gitignore", "open the .gitignore"),
        ("edit dot js and dot ts", "edit .js and .ts"),
        ("check dot json and dot yaml", "check .json and .yaml"),
        ("the dot swift file", "the .swift file"),

        // Common symbols.
        ("I need a semicolon here", "I need a ; here"),
        ("use a backslash here", "use a \\ here"),
        ("cats ampersand dogs", "cats & dogs"),
        ("wrap in backtick marks", "wrap in ` marks"),
        ("wrap in back tick marks", "wrap in ` marks"),
        ("tilde expansion", "~ expansion"),
        ("tilda expansion", "~ expansion"),

        // Hyphen joins adjacent words without leaving spaces: kebab-case
        // identifiers, CLI flags, compound modifiers.
        ("foo hyphen bar", "foo-bar"),
        ("state hyphen of hyphen the hyphen art", "state-of-the-art"),
        ("dry hyphen run flag", "dry-run flag"),

        // Language names.
        ("c plus plus is my favorite", "c++ is my favorite"),
        ("writing c sharp code", "writing C# code"),
        ("writing f sharp code", "writing F# code"),

        // Case-insensitive.
        ("DOT ENV", ".env"),
        ("Open Parentheses X Close Parenthesis", "(X)"),
    ] as [(String, String)])
    func truePositives(input: String, expected: String) {
        let processor = ReplacementProcessor(rules: SpokenSymbols.rules)
        #expect(processor.apply(to: input) == expected)
    }

    @Test(arguments: [
        // Bare "dot" not followed by a known extension stays put.
        "there is a dot on the map",

        // "the" is not in the extension list, so "dot the" doesn't fire.
        "please dot the i",

        // `\b` prevents "dot env" from hiding inside "envelope".
        "the envelope is sealed",

        // "caret" substring inside "catastrophe" — and we don't ship a
        // caret rule anyway, so this is doubly safe.
        "catastrophe",

        // Documents the excluded ` dash ` → `-` rule: this natural-English
        // phrase must pass through untouched.
        "mad dash to the finish",

        // Meta-mention of "hyphen" (not between two words) stays put
        // because the rule requires a space on both sides.
        "the writer added a hyphen.",

        // Documents the excluded `caret` → `^` rule: "carrot" must pass
        // through and never become `^`.
        "I have a carrot for lunch",

        // Documents the excluded `pipe` → `|` rule.
        "gas pipe is leaking",

        // Documents the excluded `slash` → `/` rule.
        "a slash of rain",

        // Plain input with no triggers passes through untouched.
        "hello world this is a normal sentence",
    ] as [String])
    func trueNegatives(input: String) {
        let processor = ReplacementProcessor(rules: SpokenSymbols.rules)
        #expect(processor.apply(to: input) == input)
    }

    // Spoken Symbols run before user rules, so a user rule targeting `.env`
    // sees the normalized glyph and fires as expected.
    @Test func spokenSymbolsRunBeforeUserRules() {
        let options = TranscriptionFormatter.Options(
            replacementRules: [ReplacementRule(find: ".env", replace: "DOTENV")],
            capitalization: .off,
            autoParagraph: false,
            dropTrailingPunctuation: false,
            spokenSymbolsEnabled: true,
            appendTrailingSpace: false
        )
        #expect(
            TranscriptionFormatter.format("use the dot env file", options: options)
                == "use the DOTENV file"
        )
    }

    // With the toggle off, Spoken Symbols rules do not fire even if the
    // phrase appears verbatim in the input.
    @Test func spokenSymbolsDisabledPassesThrough() {
        let options = TranscriptionFormatter.Options(
            replacementRules: [],
            capitalization: .off,
            autoParagraph: false,
            dropTrailingPunctuation: false,
            spokenSymbolsEnabled: false,
            appendTrailingSpace: false
        )
        #expect(TranscriptionFormatter.format("dot env", options: options) == "dot env")
    }
}
