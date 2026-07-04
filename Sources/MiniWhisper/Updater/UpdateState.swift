import Foundation
import Observation

/// One state of the update pipeline, mirrored from Sparkle's user-driver
/// callbacks. Cases carry the reply/cancel closures Sparkle hands us, so
/// the UI can drive the updater (install, cancel, dismiss) without touching
/// Sparkle types — this file must stay importable in non-Sparkle builds.
enum UpdateState {
    case idle
    case checking(Checking)
    case updateAvailable(Available)
    case downloading(Downloading)
    case extracting(Extracting)
    case installing
    case notFound(NotFound)
    case failed(Failure)

    struct Checking {
        let cancel: () -> Void
    }

    struct Available {
        let version: String
        let byteCount: Int64?
        /// Begins the download; the driver then chains through extract,
        /// install, and relaunch without further prompts.
        let install: () -> Void
        /// "Later" — ends the session; the update is offered again on the
        /// next check.
        let dismiss: () -> Void
    }

    struct Downloading {
        let cancel: () -> Void
        let expectedLength: UInt64?
        let receivedLength: UInt64

        /// Nil when Sparkle hasn't reported a content length (or reported
        /// zero), in which case the UI shows an indeterminate bar.
        var fraction: Double? {
            guard let expectedLength, expectedLength > 0 else { return nil }
            return min(1, Double(receivedLength) / Double(expectedLength))
        }
    }

    struct Extracting {
        let progress: Double
    }

    struct NotFound {
        let acknowledge: () -> Void
    }

    struct Failure {
        let message: String
        /// Acknowledges the error to Sparkle and clears the banner.
        let dismiss: () -> Void
    }
}

extension UpdateState {
    /// Case discriminator for equality checks — the payloads hold closures,
    /// so the enum itself can't usefully be Equatable.
    enum Phase: Equatable {
        case idle, checking, updateAvailable, downloading, extracting,
            installing, notFound, failed
    }

    var phase: Phase {
        switch self {
        case .idle: .idle
        case .checking: .checking
        case .updateAvailable: .updateAvailable
        case .downloading: .downloading
        case .extracting: .extracting
        case .installing: .installing
        case .notFound: .notFound
        case .failed: .failed
        }
    }

    var isIdle: Bool { phase == .idle }

    /// Manual checks can only start when Sparkle has no active update UI, or
    /// after a terminal result that can be acknowledged before retrying.
    var allowsManualCheck: Bool {
        switch self {
        case .idle, .notFound, .failed:
            true
        case .checking, .updateAvailable, .downloading, .extracting, .installing:
            false
        }
    }

    /// Unwinds whatever is pending so a fresh check can start cleanly.
    /// Extraction and installation can't be canceled once begun; idle has
    /// nothing to unwind.
    func cancel() {
        switch self {
        case .idle, .extracting, .installing:
            break
        case .checking(let checking):
            checking.cancel()
        case .updateAvailable(let available):
            available.dismiss()
        case .downloading(let downloading):
            downloading.cancel()
        case .notFound(let notFound):
            notFound.acknowledge()
        case .failed(let failure):
            failure.dismiss()
        }
    }
}

/// Observable holder so SwiftUI can react to update-state changes.
@MainActor
@Observable
final class UpdateViewModel {
    var state: UpdateState = .idle
}
