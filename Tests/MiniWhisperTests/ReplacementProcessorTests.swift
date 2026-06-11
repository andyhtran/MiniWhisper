import Foundation
@testable import MiniWhisper
import Testing

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

        // Boundaries are per-edge: a trailing-space `find` still anchors its
        // word-character side, so it can't start mid-word.
        ("buffoo bar foo bar", [ReplacementRule(find: "foo ", replace: "X")], "buffoo bar Xbar"),

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
            groups: [
                ReplacementGroup(
                    replacement: "b",
                    variants: [
                        ReplacementVariant(find: "a"),
                        ReplacementVariant(enabled: false, find: "c"),
                        ReplacementVariant(find: ""),
                    ]
                ),
                ReplacementGroup(
                    enabled: false,
                    replacement: "f",
                    variants: [ReplacementVariant(find: "e")]
                ),
                ReplacementGroup(
                    replacement: "h",
                    variants: [ReplacementVariant(find: "g")]
                ),
            ]
        )
        let enabled = settings.enabledRules
        #expect(enabled.count == 2)
        #expect(enabled[0].find == "a")
        #expect(enabled[1].find == "g")
    }

    @Test func defaultSettingsIncludeDisabledRemovalGroup() {
        let settings = ReplacementSettings()

        let removalGroup = settings.groups.first
        #expect(removalGroup?.isRemovalGroup == true)
        #expect(removalGroup?.enabled == false)
        #expect(removalGroup?.variants.isEmpty == true)
    }

    @Test func legacyRulesDecodeIntoGroupedSchema() throws {
        let legacyJSON = """
        {
          "enabled": true,
          "rules": [
            { "enabled": true, "find": "clawd", "replace": "Claude", "preserveCase": true },
            { "enabled": false, "find": "clawed", "replace": "Claude", "preserveCase": true },
            { "enabled": true, "find": "cloud code", "replace": "Claude Code" },
            { "enabled": true, "find": "um", "replace": "" }
          ]
        }
        """

        let settings = try JSONDecoder().decode(ReplacementSettings.self, from: Data(legacyJSON.utf8))

        #expect(settings.schemaVersion == ReplacementSettings.currentSchemaVersion)
        #expect(settings.enabled)
        #expect(settings.groups.count == 3)

        let removalGroup = try #require(settings.groups.first { $0.isRemovalGroup })
        #expect(removalGroup.enabled)
        #expect(removalGroup.variants.map(\.find) == ["um"])
        #expect(removalGroup.flattenedRules.map(\.replace) == [""])

        let claude = try #require(settings.groups.first { $0.replacement == "Claude" })
        #expect(claude.preserveCase)
        #expect(claude.variants.map(\.find) == ["clawd", "clawed"])
        #expect(claude.variants.map(\.enabled) == [true, false])
    }

    @Test func settingsEncodeVersionedGroupedSchema() throws {
        let settings = ReplacementSettings(
            enabled: true,
            groups: [
                ReplacementGroup(
                    replacement: "Claude",
                    preserveCase: true,
                    variants: [
                        ReplacementVariant(find: "clawd"),
                        ReplacementVariant(find: "clawed"),
                    ]
                ),
            ]
        )

        let data = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["schemaVersion"] as? Int == ReplacementSettings.currentSchemaVersion)
        #expect(object["rules"] == nil)
        let groups = try #require(object["groups"] as? [[String: Any]])
        #expect(groups.count == 2)
        #expect(groups.first?["replacement"] as? String == "")
    }
}
