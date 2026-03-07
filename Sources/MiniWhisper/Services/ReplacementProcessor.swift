import Foundation

struct ReplacementProcessor: Sendable {
    let rules: [ReplacementRule]

    func apply(to text: String) -> String {
        guard !rules.isEmpty else { return text }

        var result = text
        for rule in rules where !rule.find.isEmpty {
            result = result.replacingOccurrences(of: rule.find, with: rule.replace, options: .caseInsensitive)
        }
        return result
    }
}
