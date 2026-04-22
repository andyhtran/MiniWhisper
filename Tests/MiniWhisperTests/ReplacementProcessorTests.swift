import Testing
@testable import MiniWhisper

struct ReplacementProcessorTests {
    @Test(arguments: [
        // No rules — input passes through unchanged.
        ("hello", [ReplacementRule](), "hello"),

        // Empty `find` is skipped.
        ("hello", [ReplacementRule(find: "", replace: "X")], "hello"),

        // Matching is case-insensitive.
        ("Hello HELLO hello", [ReplacementRule(find: "hello", replace: "hi")], "hi hi hi"),

        // Mid-word collision is prevented by `\b`.
        ("catapult cat", [ReplacementRule(find: "cat", replace: "dog")], "catapult dog"),

        // Filler removal strips every standalone `z`; residual multi-space
        // collapses back to one.
        ("a z z z z b", [ReplacementRule(find: "z", replace: "")], "a b"),

        // Spaces in `find` are honored literally — the match consumes them,
        // so ` dash ` → `-` joins the surrounding words tightly.
        ("add dash replace", [ReplacementRule(find: " dash ", replace: "-")], "add-replace"),

        // Multi-word phrase matches as a whole phrase.
        ("hello world goodbye", [ReplacementRule(find: "hello world", replace: "hi")], "hi goodbye"),

        // Non-word-edge rule falls back to substring so `c++` still works.
        ("using c++ daily", [ReplacementRule(find: "c++", replace: "cpp")], "using cpp daily"),

        // Rules cascade within a pass, left-to-right. Equal-length `find`s
        // keep user order via stable sort.
        ("a b", [ReplacementRule(find: "a", replace: "b"), ReplacementRule(find: "b", replace: "c")], "c c"),

        // Longest `find` wins: the specific phrase replaces before the
        // shorter substring rule has a chance to claim part of it.
        ("new york times", [
            ReplacementRule(find: "new york", replace: "NYC"),
            ReplacementRule(find: "new york times", replace: "NYT"),
        ], "NYT"),

        // `$` in the replacement is literal, not a regex back-reference.
        ("price", [ReplacementRule(find: "price", replace: "$100")], "$100"),

        // Regex metacharacters in `find` are escaped — `.*` matches the
        // literal three characters.
        ("use .* matcher", [ReplacementRule(find: ".*", replace: "star")], "use star matcher"),

        // Multiple matches of the same rule all fire.
        ("foo bar foo", [ReplacementRule(find: "foo", replace: "bar")], "bar bar bar"),
    ] as [(String, [ReplacementRule], String)])
    func applyReplacements(input: String, rules: [ReplacementRule], expected: String) {
        let processor = ReplacementProcessor(rules: rules)
        #expect(processor.apply(to: input) == expected)
    }

    @Test func enabledRulesFiltersCorrectly() {
        let settings = ReplacementSettings(
            enabled: true,
            rules: [
                ReplacementRule(find: "a", replace: "b", enabled: true),
                ReplacementRule(find: "c", replace: "d", enabled: false),
                ReplacementRule(find: "", replace: "x", enabled: true),
                ReplacementRule(find: "e", replace: "f", enabled: true),
            ]
        )
        let enabled = settings.enabledRules
        #expect(enabled.count == 2)
        #expect(enabled[0].find == "a")
        #expect(enabled[1].find == "e")
    }
}
