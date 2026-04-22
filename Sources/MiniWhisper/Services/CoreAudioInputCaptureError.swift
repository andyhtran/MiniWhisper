import Foundation

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
