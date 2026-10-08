import AudioToolbox
import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let operation: String

    var description: String {
        let code = fourCC(UInt32(bitPattern: status)).map { " '\($0)'" } ?? ""
        return "\(operation) failed (OSStatus \(status)\(code))"
    }
}

/// Throws `CoreAudioError` when `status` is not `noErr`. The operation string is built only on failure.
func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    /// Reads a fixed-size POD property. `value` supplies the type and the initial value.
    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 default value: T) throws -> T {
        var address = propertyAddress(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        try check(status, "read \(propertyName(selector)) of \(self)")
        guard size == UInt32(MemoryLayout<T>.size) else {
            throw CoreAudioError(status: kAudioHardwareBadPropertySizeError,
                                 operation: "read \(propertyName(selector)) of \(self) size mismatch")
        }
        return result
    }

    /// Reads a CFString property. Core Audio returns a +1 reference, which `takeRetainedValue` balances.
    func readString(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        var address = propertyAddress(selector, scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var cf: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &cf),
                  "read string \(propertyName(selector)) of \(self)")
        guard let cf else { return "" }
        return cf.takeRetainedValue() as String
    }

    /// Writes a fixed-size POD property.
    func write<T>(_ selector: AudioObjectPropertySelector,
                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                  _ value: T) throws {
        var address = propertyAddress(selector, scope)
        var value = value
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        try check(status, "write \(propertyName(selector)) of \(self)")
    }

    /// True when the object has the property and it can be written.
    func isSettable(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = propertyAddress(selector, scope)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(self, &address)
            && AudioObjectIsPropertySettable(self, &address, &settable) == noErr
            && settable.boolValue
    }

    func readArray<T>(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      of: T.Type) throws -> [T] {
        var address = propertyAddress(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size),
                  "size of \(propertyName(selector)) of \(self)")
        let capacity = Int(size) / MemoryLayout<T>.stride
        guard capacity > 0 else { return [] }
        // The HAL reports the bytes it actually wrote, so a list that changed since the size read is handled.
        return try [T](unsafeUninitializedCapacity: capacity) { buffer, count in
            // capacity > 0 is checked above, so baseAddress is non-nil.
            var bytes = UInt32(capacity * MemoryLayout<T>.stride)
            try check(AudioObjectGetPropertyData(self, &address, 0, nil, &bytes, buffer.baseAddress!),
                      "read \(propertyName(selector)) of \(self)")
            count = Int(bytes) / MemoryLayout<T>.stride
        }
    }
}

struct AudioProcessInfo: Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
}

enum AudioSystem {
    static func defaultOutputDevice() throws -> AudioObjectID {
        let device = try AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice,
                                                   default: AudioObjectID.unknown)
        guard device != .unknown else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, operation: "no default output device")
        }
        return device
    }

    static func deviceUID(_ device: AudioObjectID) throws -> String {
        try device.readString(kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ device: AudioObjectID) throws -> String {
        try device.readString(kAudioObjectPropertyName)
    }

    static func processObjectIDs() throws -> [AudioObjectID] {
        try AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
    }

    /// Returns nil when the process object has vanished (its PID read fails).
    static func processInfo(_ object: AudioObjectID) -> AudioProcessInfo? {
        guard let pid = try? object.read(kAudioProcessPropertyPID, default: pid_t(0)) else { return nil }
        let bundle = (try? object.readString(kAudioProcessPropertyBundleID)) ?? ""
        // IsRunningOutput is a UInt32, not a Bool.
        let running = (try? object.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0
        return AudioProcessInfo(objectID: object,
                                pid: pid,
                                bundleID: bundle.isEmpty ? nil : bundle,
                                isRunningOutput: running != 0)
    }
}

/// Owns one property-listener block registration. The same block and queue are used to add and remove it.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var active = false

    init(object: AudioObjectID,
         selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         queue: DispatchQueue = .main,
         handler: @escaping () -> Void) throws {
        self.object = object
        self.queue = queue
        self.address = propertyAddress(selector, scope)
        self.block = { _, _ in handler() }
        try check(AudioObjectAddPropertyListenerBlock(object, &address, queue, block),
                  "add listener \(propertyName(selector)) on \(object)")
        active = true
    }

    deinit { cancel() }

    func cancel() {
        guard active else { return }
        active = false
        // The object may already be gone, so the status is ignored.
        _ = AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}

private func fourCC(_ value: UInt32) -> String? {
    let bytes = withUnsafeBytes(of: value.bigEndian) { Array($0) }
    guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
    return String(decoding: bytes, as: UTF8.self)
}

private func propertyName(_ selector: AudioObjectPropertySelector) -> String {
    fourCC(selector).map { "'\($0)'" } ?? "0x" + String(selector, radix: 16)
}

private func propertyAddress(_ selector: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
