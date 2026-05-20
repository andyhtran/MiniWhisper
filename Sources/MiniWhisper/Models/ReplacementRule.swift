import Foundation

struct ReplacementSettings: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var enabled: Bool
    var groups: [ReplacementGroup]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        enabled: Bool = false,
        groups: [ReplacementGroup] = []
    ) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.groups = groups
        ensureDefaultRemovalGroup()
    }

    var flattenedRules: [ReplacementRule] {
        groups.flatMap(\.flattenedRules)
    }

    var enabledRules: [ReplacementRule] {
        flattenedRules.filter { $0.enabled && !$0.find.isEmpty }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case enabled
        case groups
        case rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false

        if let decodedGroups = try container.decodeIfPresent([ReplacementGroup].self, forKey: .groups) {
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? Self.currentSchemaVersion
            groups = decodedGroups
            ensureDefaultRemovalGroup()
            return
        }

        schemaVersion = Self.currentSchemaVersion
        let legacyRules = try container.decodeIfPresent([ReplacementRule].self, forKey: .rules) ?? []
        groups = Self.groups(fromLegacyRules: legacyRules)
        ensureDefaultRemovalGroup()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(groups, forKey: .groups)
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static let defaultRemovalGroupID = UUID(uuidString: "B1878533-E109-4E24-9DC0-F3495E28C98F")!

    private static var defaultRemovalGroup: ReplacementGroup {
        ReplacementGroup(
            id: defaultRemovalGroupID,
            enabled: false,
            replacement: "",
            preserveCase: false,
            variants: []
        )
    }

    mutating func ensureDefaultRemovalGroup() {
        let removalGroups = groups.filter(\.isRemovalGroup)
        guard var removalGroup = removalGroups.first else {
            groups.insert(Self.defaultRemovalGroup, at: 0)
            return
        }

        for group in removalGroups.dropFirst() {
            removalGroup.enabled = removalGroup.enabled || group.enabled
            for variant in group.variants {
                removalGroup.appendVariantIfNeeded(variant)
            }
        }

        removalGroup.replacement = ""
        removalGroup.preserveCase = false
        groups.removeAll(where: \.isRemovalGroup)
        groups.insert(removalGroup, at: 0)
    }

    private static func groups(fromLegacyRules rules: [ReplacementRule]) -> [ReplacementGroup] {
        var groups: [ReplacementGroup] = []
        var indexesByKey: [String: Int] = [:]

        for rule in rules {
            let replacement = rule.replace.trimmingCharacters(in: .whitespacesAndNewlines)
            let find = rule.find.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !find.isEmpty else { continue }

            let key = "\(replacement)|\(rule.preserveCase)"
            let variant = ReplacementVariant(id: rule.id, enabled: rule.enabled, find: find)

            if let existingIndex = indexesByKey[key] {
                groups[existingIndex].appendVariantIfNeeded(variant)
            } else {
                indexesByKey[key] = groups.count
                groups.append(
                    ReplacementGroup(
                        enabled: true,
                        replacement: replacement,
                        preserveCase: rule.preserveCase,
                        variants: [variant]
                    )
                )
            }
        }

        return groups
    }

    private static let legacyUserDefaultsKey = "ReplacementSettings"

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("MiniWhisper/replacements.json")
    }

    static func load() -> ReplacementSettings {
        if let fromFile = loadFromFile() {
            return fromFile
        }
        // First launch after upgrade: promote the legacy UserDefaults blob to
        // the new file so subsequent loads hit the file path.
        if let legacy = loadFromUserDefaults() {
            legacy.save()
            return legacy
        }
        return ReplacementSettings()
    }

    func save() {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[MiniWhisper] Failed to write replacements.json: \(error)")
        }
    }

    private static func loadFromFile() -> ReplacementSettings? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            let settings = try JSONDecoder().decode(ReplacementSettings.self, from: data)
            if shouldRewrite(data: data) {
                settings.save()
            }
            return settings
        } catch {
            NSLog("[MiniWhisper] Failed to read replacements.json: \(error)")
            return nil
        }
    }

    private static func loadFromUserDefaults() -> ReplacementSettings? {
        guard let data = UserDefaults.standard.data(forKey: legacyUserDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ReplacementSettings.self, from: data)
    }

    private static func shouldRewrite(data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let schemaVersion = object["schemaVersion"] as? Int
        let groups = object["groups"] as? [[String: Any]] ?? []
        let hasRemovalGroup = groups.contains { group in
            let replacement = group["replacement"] as? String ?? ""
            return replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return schemaVersion != Self.currentSchemaVersion
            || object["rules"] != nil
            || object["groups"] == nil
            || !hasRemovalGroup
    }
}

struct ReplacementGroup: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var enabled: Bool
    var replacement: String
    var preserveCase: Bool
    var variants: [ReplacementVariant]

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        replacement: String,
        preserveCase: Bool = false,
        variants: [ReplacementVariant]
    ) {
        self.id = id
        self.enabled = enabled
        self.replacement = replacement
        self.preserveCase = preserveCase
        self.variants = variants
    }

    var isRemovalGroup: Bool {
        replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var flattenedRules: [ReplacementRule] {
        variants.map { variant in
            ReplacementRule(
                id: variant.id,
                find: variant.find,
                replace: replacement,
                enabled: enabled && variant.enabled,
                preserveCase: preserveCase
            )
        }
    }

    fileprivate mutating func appendVariantIfNeeded(_ variant: ReplacementVariant) {
        let normalized = variant.find.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        if let existingIndex = variants.firstIndex(where: {
            $0.find.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            variants[existingIndex].enabled = variants[existingIndex].enabled || variant.enabled
            return
        }

        variants.append(variant)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case enabled
        case replacement
        case preserveCase
        case variants
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        replacement = try container.decode(String.self, forKey: .replacement)
        preserveCase = try container.decodeIfPresent(Bool.self, forKey: .preserveCase) ?? false
        variants = try container.decodeIfPresent([ReplacementVariant].self, forKey: .variants) ?? []
    }
}

struct ReplacementVariant: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var enabled: Bool
    var find: String

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        find: String = ""
    ) {
        self.id = id
        self.enabled = enabled
        self.find = find
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case enabled
        case find
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        find = try container.decodeIfPresent(String.self, forKey: .find) ?? ""
    }
}

struct ReplacementRule: Identifiable, Hashable, Sendable {
    var id: UUID
    var find: String
    var replace: String
    var enabled: Bool
    var preserveCase: Bool

    init(
        id: UUID = UUID(),
        find: String = "",
        replace: String = "",
        enabled: Bool = true,
        preserveCase: Bool = false
    ) {
        self.id = id
        self.find = find
        self.replace = replace
        self.enabled = enabled
        self.preserveCase = preserveCase
    }
}

extension ReplacementRule: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case find
        case replace
        case enabled
        case preserveCase
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        find = try container.decodeIfPresent(String.self, forKey: .find) ?? ""
        replace = try container.decodeIfPresent(String.self, forKey: .replace) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        preserveCase = try container.decodeIfPresent(Bool.self, forKey: .preserveCase) ?? false
    }
}
