import Foundation
import CoreAudio
import AudioToolbox
import os

struct CaptureSessionInfo: Sendable {
    let deviceID: AudioDeviceID
    let deviceName: String
    let sampleRate: Double
}

final class CoreAudioInputCapture: @unchecked Sendable {
    let logger = Logger(subsystem: Logger.subsystem, category: "CoreAudioInputCapture")
    let controlQueue: DispatchQueue

    var onRMS: ((Float) -> Void)?
    var onSessionFailure: ((String) -> Void)?

    var audioUnit: AudioUnit?
    private var audioFile: ExtAudioFileRef?
    var currentDeviceID: AudioDeviceID = 0
    private var currentDeviceName = "Unknown Device"
    var isRecording = false

    private var inputFormat = AudioStreamBasicDescription()
    private var fileFormat = AudioStreamBasicDescription()

    private var renderBuffer: UnsafeMutablePointer<Float>?
    private var monoBuffer: UnsafeMutablePointer<Float>?
    private var bufferCapacityFrames: UInt32 = 0

    var listenersInstalled = false
    private var hasReportedFailure = false
    private let failureLock = NSLock()

    init(controlQueue: DispatchQueue) {
        self.controlQueue = controlQueue
    }

    deinit {
        stopRecording()
    }

    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID) throws -> CaptureSessionInfo {
        stopRecording()

        guard deviceID != 0 else {
            throw CoreAudioInputCaptureError.invalidDeviceID
        }

        currentDeviceID = deviceID
        currentDeviceName = CoreAudioDeviceQueries.queryDeviceName(deviceID) ?? "Unknown Device"
        hasReportedFailure = false

        try createAudioUnit()
        try bindInputDevice(deviceID)
        try configureInputFormat()
        try preallocateBuffers(for: deviceID)
        try installInputCallback()
        try createOutputFile(at: url)
        try startAudioUnit()
        installDeviceListeners()

        isRecording = true

        return CaptureSessionInfo(
            deviceID: currentDeviceID,
            deviceName: currentDeviceName,
            sampleRate: inputFormat.mSampleRate
        )
    }

    func stopRecording() {
        uninstallDeviceListeners()

        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }

        if let file = audioFile {
            ExtAudioFileDispose(file)
            audioFile = nil
        }

        if let renderBuffer {
            renderBuffer.deallocate()
            self.renderBuffer = nil
        }

        if let monoBuffer {
            monoBuffer.deallocate()
            self.monoBuffer = nil
        }

        bufferCapacityFrames = 0
        isRecording = false
        currentDeviceID = 0
        currentDeviceName = "Unknown Device"
        hasReportedFailure = false
    }

    private func createAudioUnit() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw CoreAudioInputCaptureError.audioUnitNotFound
        }

        var unit: AudioUnit?
        let createStatus = AudioComponentInstanceNew(component, &unit)
        guard createStatus == noErr, let unit else {
            throw CoreAudioInputCaptureError.failedToCreateAudioUnit(status: createStatus)
        }

        audioUnit = unit

        var enableInput: UInt32 = 1
        let enableStatus = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard enableStatus == noErr else {
            throw CoreAudioInputCaptureError.failedToEnableInput(status: enableStatus)
        }

        var disableOutput: UInt32 = 0
        let disableStatus = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard disableStatus == noErr else {
            throw CoreAudioInputCaptureError.failedToDisableOutput(status: disableStatus)
        }
    }

    private func bindInputDevice(_ deviceID: AudioDeviceID) throws {
        guard let audioUnit else {
            throw CoreAudioInputCaptureError.audioUnitNotInitialized
        }

        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw CoreAudioInputCaptureError.failedToSetDevice(status: status)
        }
    }

    private func configureInputFormat() throws {
        guard let audioUnit else {
            throw CoreAudioInputCaptureError.audioUnitNotInitialized
        }

        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &inputFormat,
            &size
        )
        guard formatStatus == noErr else {
            throw CoreAudioInputCaptureError.failedToGetInputFormat(status: formatStatus)
        }

        guard inputFormat.mSampleRate > 0, inputFormat.mChannelsPerFrame > 0 else {
            throw CoreAudioInputCaptureError.invalidInputFormat
        }

        var callbackFormat = AudioStreamBasicDescription(
            mSampleRate: inputFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size) * inputFormat.mChannelsPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size) * inputFormat.mChannelsPerFrame,
            mChannelsPerFrame: inputFormat.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let callbackFormatStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &callbackFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard callbackFormatStatus == noErr else {
            throw CoreAudioInputCaptureError.failedToSetCallbackFormat(status: callbackFormatStatus)
        }

        fileFormat = AudioStreamBasicDescription(
            mSampleRate: inputFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func preallocateBuffers(for deviceID: AudioDeviceID) throws {
        let preferredFrameCount = max(CoreAudioDeviceQueries.queryBufferFrameSize(deviceID), 1024)
        bufferCapacityFrames = min(max(preferredFrameCount * 4, 4096), 16384)

        renderBuffer = UnsafeMutablePointer<Float>.allocate(
            capacity: Int(bufferCapacityFrames * inputFormat.mChannelsPerFrame)
        )
        monoBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(bufferCapacityFrames))
    }

    private func installInputCallback() throws {
        guard let audioUnit else {
            throw CoreAudioInputCaptureError.audioUnitNotInitialized
        }

        var callback = AURenderCallbackStruct(
            inputProc: Self.inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            throw CoreAudioInputCaptureError.failedToSetInputCallback(status: status)
        }
    }

    private func createOutputFile(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        var fileRef: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileWAVEType,
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &fileRef
        )
        guard createStatus == noErr, let fileRef else {
            throw CoreAudioInputCaptureError.failedToCreateOutputFile(status: createStatus)
        }

        var clientFormat = fileFormat
        let clientStatus = ExtAudioFileSetProperty(
            fileRef,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard clientStatus == noErr else {
            ExtAudioFileDispose(fileRef)
            throw CoreAudioInputCaptureError.failedToSetFileFormat(status: clientStatus)
        }

        audioFile = fileRef
    }

    /// Start the audio unit with retry logic for post-sleep hardware wake-up.
    /// AudioUnitInitialize is called once, then AudioOutputUnitStart is retried
    /// because the HAL device may not be ready immediately after macOS wakes from
    /// sleep. Only the start call is retried — initialize is idempotent-safe but
    /// should not be repeated.
    private func startAudioUnit() throws {
        guard let audioUnit else {
            throw CoreAudioInputCaptureError.audioUnitNotInitialized
        }

        let initializeStatus = AudioUnitInitialize(audioUnit)
        guard initializeStatus == noErr else {
            throw CoreAudioInputCaptureError.failedToInitializeAudioUnit(status: initializeStatus)
        }

        let maxAttempts = 5
        let retryDelay: TimeInterval = 0.25

        for attempt in 1...maxAttempts {
            let startStatus = AudioOutputUnitStart(audioUnit)
            if startStatus == noErr { return }

            if attempt < maxAttempts {
                logger.warning("AudioOutputUnitStart failed (attempt \(attempt)/\(maxAttempts), status \(startStatus)), retrying in \(retryDelay)s")
                Thread.sleep(forTimeInterval: retryDelay)
            } else {
                throw CoreAudioInputCaptureError.failedToStartAudioUnit(status: startStatus)
            }
        }
    }

    private static let inputCallback: AURenderCallback = { refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
        let capture = Unmanaged<CoreAudioInputCapture>.fromOpaque(refCon).takeUnretainedValue()
        return capture.handleInput(
            ioActionFlags: ioActionFlags,
            inTimeStamp: inTimeStamp,
            inBusNumber: inBusNumber,
            inNumberFrames: inNumberFrames
        )
    }

    private func handleInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {
        guard isRecording,
              let audioUnit,
              let audioFile,
              let renderBuffer,
              let monoBuffer else {
            return noErr
        }

        guard inNumberFrames > 0 else { return noErr }
        guard inNumberFrames <= bufferCapacityFrames else {
            reportFailureAsync("Audio buffer exceeded expected size.")
            return noErr
        }

        let channelCount = inputFormat.mChannelsPerFrame
        let inputByteSize = inNumberFrames * channelCount * UInt32(MemoryLayout<Float>.size)

        var inputBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channelCount,
                mDataByteSize: inputByteSize,
                mData: renderBuffer
            )
        )

        let renderStatus = AudioUnitRender(
            audioUnit,
            ioActionFlags,
            inTimeStamp,
            inBusNumber,
            inNumberFrames,
            &inputBufferList
        )
        guard renderStatus == noErr else {
            reportFailureAsync("Audio input interrupted (\(renderStatus)).")
            return noErr
        }

        let interleaved = renderBuffer
        let channels = Int(channelCount)
        let frames = Int(inNumberFrames)

        var sumOfSquares: Float = 0
        if channels == 1 {
            for i in 0..<frames {
                let sample = interleaved[i]
                monoBuffer[i] = sample
                sumOfSquares += sample * sample
            }
        } else {
            for frame in 0..<frames {
                var mixed: Float = 0
                let base = frame * channels
                for channel in 0..<channels {
                    mixed += interleaved[base + channel]
                }
                let sample = mixed / Float(channels)
                monoBuffer[frame] = sample
                sumOfSquares += sample * sample
            }
        }

        let rms = sqrtf(sumOfSquares / Float(frames))
        onRMS?(rms)

        var outputBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: inNumberFrames * UInt32(MemoryLayout<Float>.size),
                mData: monoBuffer
            )
        )

        let writeStatus = ExtAudioFileWrite(audioFile, inNumberFrames, &outputBufferList)
        if writeStatus != noErr {
            reportFailureAsync("Failed to write audio data (\(writeStatus)).")
        }

        return noErr
    }

    func reportFailureAsync(_ message: String) {
        failureLock.lock()
        let shouldReport = !hasReportedFailure
        if shouldReport {
            hasReportedFailure = true
        }
        failureLock.unlock()

        guard shouldReport else { return }

        controlQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRecording || self.audioUnit != nil else { return }
            self.stopRecording()
            self.onSessionFailure?(message)
        }
    }

}

