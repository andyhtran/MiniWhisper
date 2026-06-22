import Foundation

enum ModelLoadPhase: Equatable, Sendable {
    case checking
    case downloading
    case preparing
}

struct ModelLoadProgress: Equatable, Sendable {
    let phase: ModelLoadPhase
    let progress: Double?
}

typealias ModelLoadProgressHandler = @Sendable (ModelLoadProgress) -> Void

enum ModelLoadState: Equatable, Sendable {
    case idle
    case loading(phase: ModelLoadPhase, progress: Double?)
    case ready
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var progress: Double? {
        if case .loading(_, let progress) = self { return progress }
        return nil
    }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
