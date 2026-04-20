import Foundation

struct ReplacementRule: Identifiable, Hashable, Sendable {
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

extension ReplacementRule: Codable {
    // `id` is deliberately omitted from the on-disk format: it's a SwiftUI
    // identity handle (ForEach, delete-by-id), not persistent data. Dropping it
    // keeps the JSON clean and makes hand-adding a rule trivial — users only
    // need to supply find/replace. Legacy files that still contain "id" are
    // silently tolerated since unknown keys are ignored on decode.
    //
    // Every other field is also optional on decode so a minimal hand-written
    // entry like {"find": "teh", "replace": "the"} loads without error.
    private enum CodingKeys: String, CodingKey {
        case find, replace, enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.find = try container.decodeIfPresent(String.self, forKey: .find) ?? ""
        self.replace = try container.decodeIfPresent(String.self, forKey: .replace) ?? ""
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(find, forKey: .find)
        try container.encode(replace, forKey: .replace)
        try container.encode(enabled, forKey: .enabled)
    }
}

struct ReplacementSettings: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var rules: [ReplacementRule] = []

    var enabledRules: [ReplacementRule] {
        rules.filter { $0.enabled && !$0.find.isEmpty }
    }

    // Pre-file-storage releases kept the whole blob here. We still read it once
    // to migrate legacy users, then leave it in place as a rollback safety net.
    // A later release will stop reading it and can delete the key.
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
            // .atomic writes to a temp file and renames — a mid-write crash
            // can't leave a half-written replacements.json on disk.
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[MiniWhisper] Failed to write replacements.json: \(error)")
        }
    }

    private static func loadFromFile() -> ReplacementSettings? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ReplacementSettings.self, from: data)
    }

    private static func loadFromUserDefaults() -> ReplacementSettings? {
        guard let data = UserDefaults.standard.data(forKey: legacyUserDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ReplacementSettings.self, from: data)
    }
}
