import Testing
@testable import MiniWhisper

struct ReplacementProcessorTests {
    @Test(arguments: [
        ("hello", [ReplacementRule](), "hello"),
        ("hello", [ReplacementRule(find: "", replace: "X")], "hello"),
        ("Hello HELLO hello", [ReplacementRule(find: "hello", replace: "hi")], "hi hi hi"),
        ("ab", [ReplacementRule(find: "a", replace: "b"), ReplacementRule(find: "b", replace: "c")], "cc"),
        ("foo bar", [ReplacementRule(find: "foo", replace: "bar")], "bar bar"),
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
