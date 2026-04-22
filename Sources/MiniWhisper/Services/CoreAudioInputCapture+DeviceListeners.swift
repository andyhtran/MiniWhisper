import Foundation
import CoreAudio
import AudioToolbox

extension CoreAudioInputCapture {
    // MARK: - Device Listeners

    func installDeviceListeners() {
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

    func uninstallDeviceListeners() {
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
}
