import Foundation
@preconcurrency import AVFoundation

/// Errors for audio decoding operations
enum AudioDecoderError: LocalizedError {
    case failedToReadInput
    case failedToCreateOutput(OSStatus)
    case failedToCreateBuffer
    case decodingFailed(OSStatus)
    
    var errorDescription: String? {
        switch self {
        case .failedToReadInput:
            return "Failed to read input audio file"
        case .failedToCreateOutput(let status):
            return "Failed to create output file: OSStatus \(status)"
        case .failedToCreateBuffer:
            return "Failed to create audio buffer"
        case .decodingFailed(let status):
            return "Decoding failed: OSStatus \(status)"
        }
    }
}

/// Decodes compressed audio files (CAF/Opus) to WAV for processing
enum AudioDecoder {
    
    /// Decodes any AVFoundation-supported audio file to 16kHz mono WAV
    /// - Parameters:
    ///   - inputURL: Source audio file URL (CAF, Opus, M4A, etc.)
    ///   - outputURL: Destination WAV file URL
    /// - Throws: AudioDecoderError if decoding fails
    static func decodeToWAV(inputURL: URL, outputURL: URL) throws {
        let inputFile = try AVAudioFile(forReading: inputURL)
        
        // Target format: 16kHz mono Float32 (ideal for Whisper)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioDecoderError.failedToCreateBuffer
        }
        
        // Create converter
        guard let converter = AVAudioConverter(from: inputFile.processingFormat, to: outputFormat) else {
            throw AudioDecoderError.decodingFailed(0)
        }
        
        // Create output file
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputFormat.settings,
            commonFormat: outputFormat.commonFormat,
            interleaved: outputFormat.isInterleaved
        )
        
        // Process in chunks
        let inputFrameCapacity: AVAudioFrameCount = 4096
        let outputFrameCapacity = AVAudioFrameCount(
            Double(inputFrameCapacity) * (outputFormat.sampleRate / inputFile.processingFormat.sampleRate)
        )
        
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFile.processingFormat,
            frameCapacity: inputFrameCapacity
        ) else {
            throw AudioDecoderError.failedToCreateBuffer
        }
        
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity + 256  // Extra for resampling
        ) else {
            throw AudioDecoderError.failedToCreateBuffer
        }
        
        while true {
            do {
                try inputFile.read(into: inputBuffer)
            } catch {
                // End of file
                break
            }
            
            if inputBuffer.frameLength == 0 {
                break
            }
            
            // Reset output buffer before each conversion
            outputBuffer.frameLength = 0
            
            // Track whether we've already provided data for this convert() call
            // AVAudioConverter may call the input block multiple times per convert()
            nonisolated(unsafe) var hasProvidedData = false
            
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if hasProvidedData {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                hasProvidedData = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            
            if status == .error, let error = error {
                throw AudioDecoderError.decodingFailed(OSStatus(error.code))
            }
            
            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
            }
        }
    }
    
    /// Creates a temporary WAV file from a compressed audio file
    /// - Parameter inputURL: Source audio file URL
    /// - Returns: URL to temporary WAV file (caller is responsible for cleanup)
    static func createTemporaryWAV(from inputURL: URL) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("decode_\(UUID().uuidString).wav")
        
        try decodeToWAV(inputURL: inputURL, outputURL: tempURL)
        
        return tempURL
    }
}
