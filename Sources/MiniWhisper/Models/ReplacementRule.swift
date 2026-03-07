import Foundation

struct ReplacementRule: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var find: String
    var replace: String
    var enabled: Bool

    init(id: UUID = UUID(), find: String = "", replace: String = "", enabled: Bool = true) {
        self.id = id
        self.find = find
        self.replace = replace
        self.enabled = enabled
    }
}

struct ReplacementSettings: Codable, Sendable {
    var enabled: Bool = false
    var rules: [ReplacementRule] = []

    var enabledRules: [ReplacementRule] {
        rules.filter { $0.enabled && !$0.find.isEmpty }
    }

    private static let storageKey = "ReplacementSettings"

    static func load() -> ReplacementSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(ReplacementSettings.self, from: data) else {
            return ReplacementSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
