import Foundation
import os.log

extension Logger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.miniwhisper"
}
