import Foundation
@preconcurrency import FluidAudio

enum ParakeetModel {
    static let version: AsrModelVersion = .v3
    static let versionName = "v3"
    static let modelName = "parakeet-tdt-v3"

    static var directory: URL {
        AsrModels.defaultCacheDirectory(for: version)
    }

    static var isInstalled: Bool {
        AsrModels.modelsExist(at: directory, version: version)
    }
}
