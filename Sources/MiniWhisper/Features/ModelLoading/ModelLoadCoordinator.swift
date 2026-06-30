import Foundation
import Observation

@Observable
@MainActor
final class ModelLoadCoordinator: Sendable {
    var state: ModelLoadState

    private let parakeet: ParakeetProvider
    private let whisper: WhisperProvider
    private let toast: ToastWindowController
    private var generation = 0

    init(
        initialMode: TranscriptionMode,
        customSettings: CustomProviderSettings,
        parakeet: ParakeetProvider,
        whisper: WhisperProvider,
        toast: ToastWindowController
    ) {
        self.parakeet = parakeet
        self.whisper = whisper
        self.toast = toast
        self.state = Self.initialState(for: initialMode, customSettings: customSettings)
    }

    func loadSelectedModel(mode: TranscriptionMode, customSettings: CustomProviderSettings) {
        generation += 1
        let loadGeneration = generation

        guard mode != .custom else {
            state = Self.initialState(for: mode, customSettings: customSettings)
            return
        }

        state = .loading(phase: .checking, progress: nil)

        Task { [weak self] in
            guard let self else { return }
            do {
                let progressHandler = self.makeProgressHandler(generation: loadGeneration)
                switch mode {
                case .default:
                    try await self.parakeet.initialize(progressHandler: progressHandler)
                case .multilingual:
                    try await self.whisper.initialize(progressHandler: progressHandler)
                case .custom:
                    return
                }

                guard self.isCurrentLoad(generation: loadGeneration) else { return }
                self.state = .ready
            } catch {
                guard self.isCurrentLoad(generation: loadGeneration) else { return }
                self.state = .failed(error.localizedDescription)
                self.toast.showError(title: "Model Load Failed", message: error.localizedDescription)
            }
        }
    }

    func refreshCustomReadiness(customSettings: CustomProviderSettings) {
        generation += 1
        state = Self.initialState(for: .custom, customSettings: customSettings)
    }

    func unload(mode: TranscriptionMode) {
        switch mode {
        case .default:
            parakeet.unload()
        case .multilingual:
            whisper.unload()
        case .custom:
            break
        }
    }

    private func makeProgressHandler(generation: Int) -> ModelLoadProgressHandler {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrentLoad(generation: generation),
                      !self.state.isReady,
                      self.state.failureMessage == nil else { return }
                self.state = .loading(phase: progress.phase, progress: progress.progress)
            }
        }
    }

    private func isCurrentLoad(generation: Int) -> Bool {
        generation == self.generation
    }

    private static func initialState(
        for mode: TranscriptionMode,
        customSettings: CustomProviderSettings
    ) -> ModelLoadState {
        switch mode {
        case .default, .multilingual:
            return .idle
        case .custom:
            return customSettings.isConfigured ? .ready : .idle
        }
    }
}
