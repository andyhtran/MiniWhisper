import CoreAudio
import Foundation
import Observation

struct AudioInputDevice: Sendable, Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

@MainActor
@Observable
final class AudioDeviceManager: Sendable {
    var availableDevices: [AudioInputDevice] = []
    var inputMode: MicInputMode = .systemDefault
    var selectedDeviceUID: String?
    var selectedDeviceName: String?

    // Cached name of the current macOS default input device, kept fresh by a listener
    var systemDefaultDeviceName: String = "Unknown"

    private static let modeKey = "MicInputMode"
    private static let uidKey = "MicSelectedDeviceUID"
    private static let nameKey = "MicSelectedDeviceName"

    init() {
        loadSettings()
        systemDefaultDeviceName = Self.querySystemDefaultInputName()
        loadDevices()
        installDeviceListListener()
        installDefaultDeviceListener()
    }

    // MARK: - Public API

    /// Returns the resolved AudioDeviceID for the current selection.
    /// nil means "use system default" (caller should not bind a specific device).
    func resolveDeviceID() -> AudioDeviceID? {
        switch inputMode {
        case .systemDefault:
            return nil
        case .specificDevice:
            guard let uid = selectedDeviceUID else { return nil }
            return availableDevices.first(where: { $0.uid == uid })?.id
        }
    }

    /// The display name for the currently effective input device.
    var effectiveDeviceName: String {
        switch inputMode {
        case .systemDefault:
            return systemDefaultDeviceName
        case .specificDevice:
            // If the device is connected, use its live name
            if let uid = selectedDeviceUID,
               let device = availableDevices.first(where: { $0.uid == uid }) {
                return device.name
            }
            // Device is disconnected — show the saved name with a hint
            if let savedName = selectedDeviceName {
                return savedName
            }
            return "Unknown Device"
        }
    }

    /// Whether the selected specific device is currently available.
    var isSelectedDeviceAvailable: Bool {
        guard inputMode == .specificDevice, let uid = selectedDeviceUID else { return true }
        return availableDevices.contains(where: { $0.uid == uid })
    }

    func selectDevice(_ device: AudioInputDevice) {
        inputMode = .specificDevice
        selectedDeviceUID = device.uid
        selectedDeviceName = device.name
        saveSettings()
    }

    func selectSystemDefault() {
        inputMode = .systemDefault
        selectedDeviceUID = nil
        selectedDeviceName = nil
        saveSettings()
    }

    // MARK: - Device Enumeration

    private func loadDevices() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else {
            availableDevices = []
            return
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else {
            availableDevices = []
            return
        }

        availableDevices = deviceIDs.compactMap { deviceID in
            guard isInputDevice(deviceID),
                  let uid = getDeviceUID(deviceID),
                  let name = getDeviceName(deviceID) else {
                return nil
            }
            return AudioInputDevice(id: deviceID, uid: uid, name: name)
        }
    }

    /// Returns true if the device has at least one input channel.
    private func isInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else { return false }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(
            capacity: Int(dataSize) / MemoryLayout<AudioBufferList>.size + 1
        )
        defer { bufferListPointer.deallocate() }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPointer)
        guard status == noErr else { return false }

        return bufferListPointer.pointee.mNumberBuffers > 0
    }

    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let cfUID = uid?.takeRetainedValue() else { return nil }
        return cfUID as String
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &nameRef)
        guard status == noErr, let cfName = nameRef?.takeRetainedValue() else { return nil }
        return cfName as String
    }

    // MARK: - System Default Query

    nonisolated static func querySystemDefaultInputName() -> String {
        var deviceID = AudioObjectID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return "System Default"
        }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let nameStatus = AudioObjectGetPropertyData(
            deviceID,
            &nameAddress,
            0, nil,
            &nameSize,
            &nameRef
        )

        if nameStatus == noErr, let cfName = nameRef?.takeRetainedValue() {
            return cfName as String
        }
        return "System Default"
    }

    // MARK: - Listeners

    private func installDeviceListListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                self.loadDevices()
            }
        }
    }

    private func installDefaultDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                self.systemDefaultDeviceName = Self.querySystemDefaultInputName()
            }
        }
    }

    // MARK: - Persistence

    private func loadSettings() {
        if let rawMode = UserDefaults.standard.string(forKey: Self.modeKey),
           let mode = MicInputMode(rawValue: rawMode) {
            inputMode = mode
        }
        selectedDeviceUID = UserDefaults.standard.string(forKey: Self.uidKey)
        selectedDeviceName = UserDefaults.standard.string(forKey: Self.nameKey)
    }

    private func saveSettings() {
        UserDefaults.standard.set(inputMode.rawValue, forKey: Self.modeKey)
        if let uid = selectedDeviceUID {
            UserDefaults.standard.set(uid, forKey: Self.uidKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.uidKey)
        }
        if let name = selectedDeviceName {
            UserDefaults.standard.set(name, forKey: Self.nameKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.nameKey)
        }
    }
}
