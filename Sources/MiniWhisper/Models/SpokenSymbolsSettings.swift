import Foundation

enum SpokenSymbolsSettings {
    private static let key = "SpokenSymbolsEnabled"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
