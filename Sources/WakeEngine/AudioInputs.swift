import CoreAudio
import Foundation

/// An audio input device. `uid` is Core Audio's persistent identifier (stable across reconnects and
/// restarts, unlike `id`), so a chosen microphone is remembered by it.
public struct AudioInput: Identifiable, Hashable, Sendable {
    public enum Transport: Sendable { case builtIn, bluetooth, continuity, usb, other }
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let transport: Transport
    public init(id: AudioDeviceID, uid: String, name: String, transport: Transport) {
        self.id = id; self.uid = uid; self.name = name; self.transport = transport
    }
}

/// HeyDot records from the built-in microphone unless the user picked another input, and never follows the
/// macOS default input. Headphones that are shared with a phone (Bluetooth) or an iPhone's Continuity
/// microphone become the default the moment they connect; following them would grab the headset's
/// microphone and keep taking it back from the phone's calls.
public enum AudioInputs {
    /// The input to record from: the chosen device while it is connected, otherwise the built-in microphone.
    /// Never whatever the default input is; nil when there is neither (a Mac without a built-in microphone
    /// whose user hasn't picked one).
    public static func choose(preferredUID: String?, among inputs: [AudioInput]) -> AudioInput? {
        if let preferredUID, let chosen = inputs.first(where: { $0.uid == preferredUID }) { return chosen }
        return inputs.first { $0.transport == .builtIn }
    }

    /// The UID of the device to record from right now, from the live device list.
    public static func current(preferredUID: String?) -> String? { choose(preferredUID: preferredUID, among: all())?.uid }

    public static func all() -> [AudioInput] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput).compactMap { id in
            guard let name = string(id, kAudioObjectPropertyName), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioInput(id: id, uid: uid, name: name, transport: transport(id))
        }
    }

    /// Calls `changed` on the main actor when devices connect or disconnect. Returns a cancel closure.
    static let watchDevices: InputWatch = { changed in
        var address = address(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { changed() } }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        guard status == noErr else { return {} }
        return {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func transport(_ id: AudioDeviceID) -> AudioInput.Transport {
        var a = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return .other }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return .continuity
        case kAudioDeviceTransportTypeUSB: return .usb
        default: return .other
        }
    }
}
