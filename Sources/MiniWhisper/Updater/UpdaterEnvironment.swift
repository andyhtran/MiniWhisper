import SwiftUI

private struct UpdaterControllerEnvironmentKey: EnvironmentKey {
    static let defaultValue: UpdaterProviding? = nil
}

extension EnvironmentValues {
    var updaterController: UpdaterProviding? {
        get { self[UpdaterControllerEnvironmentKey.self] }
        set { self[UpdaterControllerEnvironmentKey.self] = newValue }
    }
}
