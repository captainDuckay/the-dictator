import Combine
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    let uid: String
    let name: String
    let isAvailable: Bool
    let isSystemDefault: Bool
    let sampleRate: Double?

    var id: String { uid }
}

enum AudioInputSelectionResolution {
    case systemDefault(defaultDevice: AudioInputDevice?)
    case specificAvailable(device: AudioInputDevice)
    case specificUnavailable(selectedUID: String, selectedName: String, fallbackDevice: AudioInputDevice?)
}

@MainActor
final class AudioInputDeviceService: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []

    private let listenerQueue = DispatchQueue(label: "the-dictator.audio-input-listener")
    private var hasRegisteredListeners = false
    private var refreshDebounceWorkItem: DispatchWorkItem?

    init() {
        refreshDevices()
        registerPropertyListeners()
    }

    func refreshDevices() {
        let defaultID = Self.systemDefaultInputDeviceID()
        let deviceIDs = Self.inputDeviceIDs()

        let discoveredDevices = deviceIDs.compactMap { deviceID -> AudioInputDevice? in
            guard let uid = Self.deviceUID(deviceID), let name = Self.deviceName(deviceID) else {
                return nil
            }

            let isAlive = Self.isDeviceAlive(deviceID)
            let hasInputStreams = Self.deviceHasInputStreams(deviceID)
            let sampleRate = Self.deviceSampleRate(deviceID)

            return AudioInputDevice(
                uid: uid,
                name: name,
                isAvailable: isAlive && hasInputStreams,
                isSystemDefault: deviceID == defaultID,
                sampleRate: sampleRate
            )
        }

        devices = discoveredDevices.sorted {
            if $0.isSystemDefault != $1.isSystemDefault {
                return $0.isSystemDefault && !$1.isSystemDefault
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func resolve(preference: AudioInputPreference, preferredName: String) -> AudioInputSelectionResolution {
        switch preference {
        case .systemDefault:
            return .systemDefault(defaultDevice: systemDefaultInputDevice())
        case .specificDevice(let uid):
            if let preferredDevice = devices.first(where: { $0.uid == uid && $0.isAvailable }) {
                return .specificAvailable(device: preferredDevice)
            }

            let fallback = systemDefaultInputDevice()
            return .specificUnavailable(selectedUID: uid, selectedName: preferredName, fallbackDevice: fallback)
        }
    }

    func systemDefaultInputDevice() -> AudioInputDevice? {
        devices.first(where: { $0.isSystemDefault })
    }

    func inputDevice(forUID uid: String) -> AudioInputDevice? {
        devices.first(where: { $0.uid == uid })
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        devices.contains(where: { $0.uid == uid && $0.isAvailable }) ? Self.audioDeviceID(forUID: uid) : nil
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        Self.systemDefaultInputDeviceID()
    }

    private func scheduleRefresh() {
        refreshDebounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }

        refreshDebounceWorkItem = workItem
        listenerQueue.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func registerPropertyListeners() {
        guard !hasRegisteredListeners else { return }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let resultA = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            listenerQueue
        ) { [weak self] _, _ in
            self?.scheduleRefresh()
        }

        let resultB = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            listenerQueue
        ) { [weak self] _, _ in
            self?.scheduleRefresh()
        }

        if resultA == noErr && resultB == noErr {
            hasRegisteredListeners = true
        } else {
            AppLogger.error(AppLogger.app, "Failed to register audio device listeners. statusA=\(resultA) statusB=\(resultB)")
        }
    }

    private static func inputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard
            let size = propertyDataSize(objectID: AudioObjectID(kAudioObjectSystemObject), address: &address),
            size > 0
        else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)

        var mutableSize = size
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &mutableSize,
            &deviceIDs
        )

        guard status == noErr else {
            AppLogger.error(AppLogger.app, "Failed to query audio devices: status=\(status)")
            return []
        }

        return deviceIDs.filter { deviceHasInputStreams($0) }
    }

    private static func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.stride)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else {
            return nil
        }

        return deviceID
    }

    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        inputDeviceIDs().first(where: { deviceUID($0) == uid })
    }

    private static func deviceHasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard let size = propertyDataSize(objectID: deviceID, address: &address) else {
            return false
        }

        return size > 0
    }

    private static func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isAlive)
        return status == noErr && isAlive != 0
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfName)
        return status == noErr ? (cfName?.takeUnretainedValue() as String?) : nil
    }

    private static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var cfUID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfUID)
        return status == noErr ? (cfUID?.takeUnretainedValue() as String?) : nil
    }

    private static func deviceSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var sampleRate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        return status == noErr ? sampleRate : nil
    }

    private static func propertyDataSize(objectID: AudioObjectID, address: inout AudioObjectPropertyAddress) -> UInt32? {
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        return status == noErr ? size : nil
    }
}
