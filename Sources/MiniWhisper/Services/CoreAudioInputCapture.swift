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
    private let logger = Logger(subsystem: Logger.subsystem, category: "CoreAudioInputCapture")
    private let controlQueue: DispatchQueue

    var onRMS: ((Float) -> Void)?
    var onSessionFailure: ((String) -> Void)?

    private var audioUnit: AudioUnit?
    private var audioFile: ExtAudioFileRef?
    private var currentDeviceID: AudioDeviceID = 0
    private var currentDeviceName = "Unknown Device"
    private var isRecording = false

    private var inputFormat = AudioStreamBasicDescription()
    private var fileFormat = AudioStreamBasicDescription()

    private var renderBuffer: UnsafeMutablePointer<Float>?
    private var monoBuffer: UnsafeMutablePointer<Float>?
    private var bufferCapacityFrames: UInt32 = 0

    private var listenersInstalled = false
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
        currentDeviceName = Self.queryDeviceName(deviceID) ?? "Unknown Device"
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
        let preferredFrameCount = max(Self.queryBufferFrameSize(deviceID), 1024)
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

    private func installDeviceListeners() {
        guard !listenersInstalled else { return }

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let aliveStatus = AudioObjectAddPropertyListener(
            currentDeviceID,
            &aliveAddress,
            Self.devicePropertyListener,
            userData
        )

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesStatus = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            Self.devicePropertyListener,
            userData
        )

        if aliveStatus == noErr && devicesStatus == noErr {
            listenersInstalled = true
        } else {
            if aliveStatus == noErr {
                AudioObjectRemovePropertyListener(
                    currentDeviceID,
                    &aliveAddress,
                    Self.devicePropertyListener,
                    userData
                )
            }
            if devicesStatus == noErr {
                AudioObjectRemovePropertyListener(
                    AudioObjectID(kAudioObjectSystemObject),
                    &devicesAddress,
                    Self.devicePropertyListener,
                    userData
                )
            }
            listenersInstalled = false
            logger.error("Failed to install device listeners (alive: \(aliveStatus), devices: \(devicesStatus))")
        }
    }

    private func uninstallDeviceListeners() {
        guard listenersInstalled else { return }

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            currentDeviceID,
            &aliveAddress,
            Self.devicePropertyListener,
            userData
        )

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            Self.devicePropertyListener,
            userData
        )

        listenersInstalled = false
    }

    private static let devicePropertyListener: AudioObjectPropertyListenerProc = { _, _, _, userData in
        guard let userData else { return noErr }
        let capture = Unmanaged<CoreAudioInputCapture>.fromOpaque(userData).takeUnretainedValue()
        capture.controlQueue.async { [weak capture] in
            capture?.validateActiveDevice()
        }
        return noErr
    }

    private func validateActiveDevice() {
        guard isRecording else { return }

        var alive: UInt32 = 0
        var aliveSize = UInt32(MemoryLayout<UInt32>.size)
        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let aliveStatus = AudioObjectGetPropertyData(
            currentDeviceID,
            &aliveAddress,
            0,
            nil,
            &aliveSize,
            &alive
        )
        guard aliveStatus == noErr, alive != 0 else {
            reportFailureAsync("Selected microphone disconnected during recording.")
            return
        }

        guard let audioUnit else { return }
        var routedDevice = AudioDeviceID(0)
        var routedSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let routeStatus = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &routedDevice,
            &routedSize
        )
        guard routeStatus == noErr, routedDevice == currentDeviceID else {
            reportFailureAsync("Selected microphone routing changed during recording.")
            return
        }
    }

    private func reportFailureAsync(_ message: String) {
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

    private static func queryBufferFrameSize(_ deviceID: AudioDeviceID) -> UInt32 {
        var frameSize: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &frameSize
        )
        if status == noErr, frameSize > 0 {
            return frameSize
        }
        return 1024
    }

    private static func queryDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &nameRef)
        guard status == noErr, let name = nameRef?.takeRetainedValue() else { return nil }
        return name as String
    }
}

enum CoreAudioInputCaptureError: LocalizedError {
    case invalidDeviceID
    case audioUnitNotFound
    case audioUnitNotInitialized
    case invalidInputFormat
    case failedToCreateAudioUnit(status: OSStatus)
    case failedToEnableInput(status: OSStatus)
    case failedToDisableOutput(status: OSStatus)
    case failedToSetDevice(status: OSStatus)
    case failedToGetInputFormat(status: OSStatus)
    case failedToSetCallbackFormat(status: OSStatus)
    case failedToSetInputCallback(status: OSStatus)
    case failedToCreateOutputFile(status: OSStatus)
    case failedToSetFileFormat(status: OSStatus)
    case failedToInitializeAudioUnit(status: OSStatus)
    case failedToStartAudioUnit(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidDeviceID:
            return "Invalid input device"
        case .audioUnitNotFound:
            return "Failed to create audio capture unit"
        case .audioUnitNotInitialized:
            return "Audio capture is not initialized"
        case .invalidInputFormat:
            return "Input device has an invalid stream format"
        case .failedToCreateAudioUnit(let status):
            return "Failed to create audio unit (\(status))"
        case .failedToEnableInput(let status):
            return "Failed to enable audio input (\(status))"
        case .failedToDisableOutput(let status):
            return "Failed to configure output path (\(status))"
        case .failedToSetDevice(let status):
            return "Failed to bind selected microphone (\(status))"
        case .failedToGetInputFormat(let status):
            return "Failed to query input stream format (\(status))"
        case .failedToSetCallbackFormat(let status):
            return "Failed to configure callback stream format (\(status))"
        case .failedToSetInputCallback(let status):
            return "Failed to install audio input callback (\(status))"
        case .failedToCreateOutputFile(let status):
            return "Failed to create recording file (\(status))"
        case .failedToSetFileFormat(let status):
            return "Failed to configure recording file format (\(status))"
        case .failedToInitializeAudioUnit(let status):
            return "Failed to initialize audio capture (\(status))"
        case .failedToStartAudioUnit(let status):
            return "Failed to start audio capture (\(status))"
        }
    }
}
