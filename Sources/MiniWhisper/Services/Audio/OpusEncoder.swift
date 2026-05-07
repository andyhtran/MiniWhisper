@preconcurrency import AVFoundation
import AudioToolbox

enum OpusEncoderError: Error, LocalizedError {
    case failedToCreateInputFormat
    case failedToCreateOutputFormat
    case failedToCreateConverter
    case failedToCreateOutputFile(OSStatus)
    case failedToReadInputFile
    case encodingFailed(OSStatus)
    case unsupportedInputFormat
    
    var errorDescription: String? {
        switch self {
        case .failedToCreateInputFormat:
            return "Failed to create input audio format"
        case .failedToCreateOutputFormat:
            return "Failed to create Opus output format"
        case .failedToCreateConverter:
            return "Failed to create audio converter"
        case .failedToCreateOutputFile(let status):
            return "Failed to create output file: OSStatus \(status)"
        case .failedToReadInputFile:
            return "Failed to read input audio file"
        case .encodingFailed(let status):
            return "Encoding failed: OSStatus \(status)"
        case .unsupportedInputFormat:
            return "Input format not supported for Opus encoding"
        }
    }
}

/// Encodes audio files to Opus format using AudioToolbox (macOS 14+)
enum OpusEncoder {

    /// Opus bitrate for speech (48 kbps provides excellent quality for voice)
    private static let opusBitrate: UInt32 = 48000

    /// Opus output sample rate (48kHz is Opus's native rate for best quality)
    private static let opusSampleRate: Double = 48000

    /// Encodes a WAV file to Opus in CAF container
    /// - Parameters:
    ///   - inputURL: Source WAV file URL (any sample rate, mono or stereo)
    ///   - outputURL: Destination CAF file URL (will contain Opus audio)
    /// - Throws: OpusEncoderError if encoding fails
    static func encode(inputURL: URL, outputURL: URL) throws {
        let inputFile = try AVAudioFile(forReading: inputURL)
        let inputFormat = inputFile.processingFormat

        // Opus supports: 8000, 12000, 16000, 24000, 48000 Hz
        // We use 48kHz for best quality, ExtAudioFile handles resampling
        var outputDescription = AudioStreamBasicDescription(
            mSampleRate: opusSampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960,  // 20ms at 48kHz
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,   // Always mono output for speech
            mBitsPerChannel: 0,
            mReserved: 0
        )
        
        var outputFile: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            outputURL as CFURL,
            kAudioFileCAFType,
            &outputDescription,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &outputFile
        )
        
        guard status == noErr, let outputFile = outputFile else {
            throw OpusEncoderError.failedToCreateOutputFile(status)
        }
        
        defer { ExtAudioFileDispose(outputFile) }

        // Set the client format - this is the format we provide data in
        // ExtAudioFile will handle conversion from this format to Opus
        // Use the input format but force mono if stereo
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: inputFormat.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,  // Always mono
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = ExtAudioFileSetProperty(
            outputFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )

        guard status == noErr else {
            throw OpusEncoderError.encodingFailed(status)
        }

        // Create mono format for reading input (in case input is stereo)
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw OpusEncoderError.failedToCreateInputFormat
        }
        
        var bitrate = opusBitrate
        var converter: AudioConverterRef?
        var converterSize = UInt32(MemoryLayout<AudioConverterRef>.size)
        status = ExtAudioFileGetProperty(
            outputFile,
            kExtAudioFileProperty_AudioConverter,
            &converterSize,
            &converter
        )
        
        if status == noErr, let converter = converter {
            AudioConverterSetProperty(
                converter,
                kAudioConverterEncodeBitRate,
                UInt32(MemoryLayout<UInt32>.size),
                &bitrate
            )
        }
        
        let bufferFrames: AVAudioFrameCount = 4096

        // Buffer for reading from input file (may be stereo)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: bufferFrames) else {
            throw OpusEncoderError.failedToCreateInputFormat
        }

        // Buffer for writing to output (always mono)
        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: bufferFrames) else {
            throw OpusEncoderError.failedToCreateInputFormat
        }

        // Create converter for stereo-to-mono if needed
        let needsMonoConversion = inputFormat.channelCount > 1
        let monoConverter: AVAudioConverter? = needsMonoConversion
            ? AVAudioConverter(from: inputFormat, to: monoFormat)
            : nil

        while true {
            // AVAudioFile.read() may throw when reaching end of file with partial data
            // but the buffer can still contain valid frames to write
            do {
                try inputFile.read(into: inputBuffer)
            } catch {
                // End of file - write any remaining frames
                if inputBuffer.frameLength > 0 {
                    let writeBuffer = try convertToMono(
                        inputBuffer: inputBuffer,
                        monoBuffer: monoBuffer,
                        converter: monoConverter,
                        needsConversion: needsMonoConversion
                    )
                    status = ExtAudioFileWrite(outputFile, writeBuffer.frameLength, writeBuffer.audioBufferList)
                    if status != noErr {
                        throw OpusEncoderError.encodingFailed(status)
                    }
                }
                break
            }

            if inputBuffer.frameLength == 0 {
                break
            }

            let writeBuffer = try convertToMono(
                inputBuffer: inputBuffer,
                monoBuffer: monoBuffer,
                converter: monoConverter,
                needsConversion: needsMonoConversion
            )

            status = ExtAudioFileWrite(outputFile, writeBuffer.frameLength, writeBuffer.audioBufferList)

            guard status == noErr else {
                throw OpusEncoderError.encodingFailed(status)
            }
        }
    }

    /// Converts stereo buffer to mono, or returns input if already mono
    private static func convertToMono(
        inputBuffer: AVAudioPCMBuffer,
        monoBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        needsConversion: Bool
    ) throws -> AVAudioPCMBuffer {
        guard needsConversion, let converter = converter else {
            return inputBuffer
        }

        monoBuffer.frameLength = 0
        
        // Track whether we've already provided data for this convert() call
        // AVAudioConverter may call the input block multiple times per convert()
        nonisolated(unsafe) var hasProvidedData = false
        
        var error: NSError?

        converter.convert(to: monoBuffer, error: &error) { _, outStatus in
            if hasProvidedData {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedData = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let error = error {
            throw OpusEncoderError.encodingFailed(OSStatus(error.code))
        }

        return monoBuffer
    }
    
    /// Encodes audio data to Opus in CAF container
    /// - Parameters:
    ///   - audioData: Raw audio file data (WAV format, any sample rate)
    ///   - outputURL: Destination CAF file URL
    /// - Throws: OpusEncoderError if encoding fails
    static func encode(audioData: Data, to outputURL: URL) throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opus_temp_\(UUID().uuidString).wav")
        
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        try audioData.write(to: tempURL)
        try encode(inputURL: tempURL, outputURL: outputURL)
    }
}
