import Foundation
import Testing
@testable import MiniWhisper

@MainActor
struct RecordingRecoveryTests {
    @Test func failedRecordingWithAudioAppearsInHistoryAndCanRetry() throws {
        let store = RecordingStore()
        let recording = makeRecording(status: .failed)
        defer { cleanup(recording) }

        try writeAudioFile(for: recording)
        try store.saveFailedRecording(recording)

        let items = store.historyItems(limit: 10)
        #expect(items.contains { $0.id == recording.id })
        #expect(items.first { $0.id == recording.id }?.canRetranscribe == true)
    }

    @Test func inProgressRecordingIsHiddenFromHistory() throws {
        let store = RecordingStore()
        let recording = makeRecording(status: .recording)
        defer { cleanup(recording) }

        try store.saveMetadataOnly(recording)

        #expect(store.historyItems(limit: 10).contains { $0.id == recording.id } == false)
    }

    @Test func loadAllRecoversStaleInProgressRecordingWithAudioAsFailed() async throws {
        let recording = makeRecording(status: .recording)
        defer { cleanup(recording) }

        try writeAudioFile(for: recording)
        try RecordingStore().saveMetadataOnly(recording)

        let loadedStore = RecordingStore()
        try await loadedStore.loadAll()

        let recovered = loadedStore.recordings.first { $0.id == recording.id }
        #expect(recovered?.status == .failed)
        #expect(recovered?.isVisibleInHistory == true)
        #expect(recovered?.canRetranscribe == true)
    }

    private func makeRecording(status: RecordingStatus) -> Recording {
        Recording(
            id: "test-\(UUID().uuidString)",
            createdAt: Date(),
            recording: RecordingInfo(
                duration: 3,
                sampleRate: 16_000,
                channels: 1,
                fileSize: 4,
                inputDevice: "Test Microphone"
            ),
            transcription: nil,
            configuration: RecordingConfiguration(
                voiceModel: "test-model",
                language: "auto",
                provider: TranscriptionMode.custom.rawValue
            ),
            status: status
        )
    }

    private func writeAudioFile(for recording: Recording) throws {
        try FileManager.default.createDirectory(
            at: recording.storageDirectory,
            withIntermediateDirectories: true
        )
        try Data([0, 1, 2, 3]).write(to: recording.audioURL)
    }

    private func cleanup(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.storageDirectory)
    }
}
