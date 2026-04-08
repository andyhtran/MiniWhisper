import Testing
@testable import MiniWhisper

struct MeterNormalizationTests {

    // MARK: - rmsToDBFS

    @Test func silenceReturnsFloor() {
        #expect(AudioRecorder.rmsToDBFS(0) == -60)
    }

    @Test func fullScaleReturnsZero() {
        // RMS of 1.0 = 0 dBFS
        let db = AudioRecorder.rmsToDBFS(1.0)
        #expect(abs(db) < 0.001)
    }

    @Test func halfAmplitudeIsAboutMinus6dB() {
        let db = AudioRecorder.rmsToDBFS(0.5)
        // 20 * log10(0.5) ≈ -6.02
        #expect(db > -6.1 && db < -5.9)
    }

    @Test func veryQuietClampsToFloor() {
        // Extremely tiny RMS should clamp to -60 rather than going to -inf
        let db = AudioRecorder.rmsToDBFS(1e-10)
        #expect(db == -60)
    }

    // MARK: - normalizeMeter

    @Test func belowNoiseGateIsZero() {
        // -50 dBFS is well below the -42 gate
        #expect(AudioRecorder.normalizeMeter(dbFS: -50) == 0)
        #expect(AudioRecorder.normalizeMeter(dbFS: -42) == 0)
    }

    @Test func atCeilingIsOne() {
        #expect(AudioRecorder.normalizeMeter(dbFS: -12) == 1.0)
    }

    @Test func aboveCeilingClampsToOne() {
        #expect(AudioRecorder.normalizeMeter(dbFS: 0) == 1.0)
    }

    @Test func midpointIsHalf() {
        // Midpoint between -42 and -12 is -27
        let result = AudioRecorder.normalizeMeter(dbFS: -27)
        #expect(result == 0.5)
    }

    @Test func monotonicIncrease() {
        let values: [Float] = [-45, -42, -35, -27, -20, -12, -5, 0]
        var previous = -1.0
        for db in values {
            let level = AudioRecorder.normalizeMeter(dbFS: db)
            #expect(level >= previous, "normalizeMeter should be monotonically non-decreasing")
            previous = level
        }
    }
}
