import Testing
@testable import MiniWhisper

struct SpokenSymbolsCatalogTests {
    private var allEntries: [SpokenSymbolsCatalog.Entry] {
        SpokenSymbolsCatalog.Category.allCases.flatMap {
            SpokenSymbolsCatalog.entries(in: $0)
        }
    }

    @Test func everyRuleOutputAppearsExactlyOnce() {
        let outputs = allEntries.map(\.output)
        #expect(outputs.count == Set(outputs).count)
        #expect(Set(outputs) == Set(SpokenSymbols.rules.map(\.replace)))
    }

    @Test func phraseVariantsCollapseIntoOneEntry() {
        let openParen = allEntries.first { $0.output == "(" }
        #expect(openParen?.phrases == ["open parentheses", "open parenthesis", "open paren"])

        let backslash = allEntries.first { $0.output == "\\" }
        #expect(backslash?.phrases == ["backslash", "back slash"])

        // The two slash rule forms are the same spoken word, so they must
        // collapse to a single phrase.
        let slash = allEntries.first { $0.output == "/" }
        #expect(slash?.phrases == ["slash"])
    }

    @Test func phrasesAreStrippedOfMatcherPadding() {
        for entry in allEntries {
            for phrase in entry.phrases {
                #expect(!phrase.isEmpty)
                #expect(phrase == SpokenSymbolsCatalog.displayPhrase(for: phrase))
            }
        }
    }

    @Test func categoriesClassifyKnownOutputs() {
        #expect(
            SpokenSymbolsCatalog.entries(in: .pairedDelimiters).map(\.output)
                == ["(", ")", "[", "]", "{", "}"]
        )
        #expect(
            SpokenSymbolsCatalog.entries(in: .fileExtensions)
                .allSatisfy { $0.output.hasPrefix(".") }
        )
        let symbols = SpokenSymbolsCatalog.entries(in: .symbols).map(\.output)
        #expect(symbols.contains(";"))
        #expect(symbols.contains("/"))
        #expect(symbols.contains("|"))
        #expect(
            SpokenSymbolsCatalog.entries(in: .languageNames).map(\.output)
                == ["c++", "C#", "F#"]
        )
    }

    @Test func wordJoiningEntriesAreHyphenAndSlash() {
        let joining = allEntries.filter(\.joinsWords)
        #expect(joining.map(\.output) == ["-", "/"])
    }

    // The UI presents exclusions as "deliberately not supported". If one of
    // them ever ships as a real rule, the list would lie in both directions.
    @Test func exclusionsNeverAppearAsRules() {
        let shippedPhrases = Set(
            SpokenSymbols.rules.map { SpokenSymbolsCatalog.displayPhrase(for: $0.find) }
        )
        for exclusion in SpokenSymbolsCatalog.exclusions {
            #expect(!shippedPhrases.contains(exclusion.phrase))
        }
    }
}
