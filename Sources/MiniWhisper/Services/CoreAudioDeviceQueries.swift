import Foundation
import CoreAudio

enum CoreAudioDeviceQueries {
    static func queryBufferFrameSize(_ deviceID: AudioDeviceID) -> UInt32 {
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

    static func queryDeviceName(_ deviceID: AudioDeviceID) -> String? {
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
