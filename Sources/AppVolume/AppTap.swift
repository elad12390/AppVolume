import Foundation
import CoreAudio
import AudioToolbox
import Synchronization

/// Shared with the IO block. `target` is written on main and read on IO. `applied` is IO-only.
private final class IOState: Sendable {
    let target: Atomic<UInt32>   // Float bit pattern
    let applied: Atomic<UInt32>  // Float bit pattern of the gain the last buffer ended at
    let inputSkip: Int           // leading input buffers that belong to the output sub-device, not the tap

    init(gain: Float, inputSkip: Int) {
        target = Atomic(gain.bitPattern)
        applied = Atomic(gain.bitPattern)
        self.inputSkip = inputSkip
    }
}

/// One app's tap + private aggregate device + IOProc. Owned by VolumeController on the main actor.
final class AppTap {
    /// Highest gain: 2.0 = 200%. Anything above 1.0 is boost and goes through the soft limiter.
    static let maxGain: Float = 2
    let processObjectIDs: [AudioObjectID]   // sorted, as passed in
    let outputDeviceID: AudioObjectID
    private let state: IOState
    private let ioQueue: DispatchQueue
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?

    init(processObjectIDs: [AudioObjectID], outputDeviceID: AudioObjectID, name: String, gain: Float) throws {
        self.processObjectIDs = processObjectIDs.sorted()
        self.outputDeviceID = outputDeviceID
        // An output device with inputs (headset mic, audio interface) exposes those streams ahead of the tap's.
        let skip = (try? outputDeviceID.readArray(kAudioDevicePropertyStreams,
                                                  scope: kAudioObjectPropertyScopeInput,
                                                  of: AudioStreamID.self).count) ?? 0
        state = IOState(gain: Self.clamp(gain), inputSkip: skip)
        ioQueue = DispatchQueue(label: "AppVolume.io.\(name)", qos: .userInteractive)
        do { try build(name: name) } catch { invalidate(); throw error }
    }

    var gain: Float {
        get { Float(bitPattern: state.target.load(ordering: .relaxed)) }
        set { state.target.store(Self.clamp(newValue).bitPattern, ordering: .relaxed) }
    }

    deinit { invalidate() }

    /// Idempotent teardown on main. Statuses are ignored and every step runs even if an earlier one failed.
    func invalidate() {
        if let proc = procID {
            _ = AudioDeviceStop(aggregateID, proc)
            _ = AudioDeviceDestroyIOProcID(aggregateID, proc)
            procID = nil
        }
        if aggregateID != .unknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID != .unknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }

    private static func clamp(_ value: Float) -> Float {
        value.isNaN ? 0 : min(max(value, 0), maxGain)
    }

    private func build(name: String) throws {
        guard !processObjectIDs.isEmpty else {
            throw CoreAudioError(status: kAudioHardwareIllegalOperationError,
                                 operation: "create process tap (no processes)")
        }
        let desc = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        desc.uuid = UUID()
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        desc.name = "AppVolume \(name)"
        var tap = AudioObjectID.unknown
        try check(AudioHardwareCreateProcessTap(desc, &tap), "create process tap")
        tapID = tap

        let outputUID = try AudioSystem.deviceUID(outputDeviceID)
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppVolume \(name)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var aggregate = AudioObjectID.unknown
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate),
                  "create aggregate device")
        aggregateID = aggregate

        // The block captures only the state box, never self.
        let state = self.state
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, ioQueue) { _, input, _, output, _ in
            AppTap.render(state, input: input, output: output)
        }, "create IO proc")
        procID = proc

        if state.inputSkip > 0 { disableSubDeviceInputs() }
        try check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
    }

    /// Best effort: keeps our IOProc from opening the output sub-device's own input streams (mic on a headset).
    /// The tap stream stays on. Failures are ignored.
    private func disableSubDeviceInputs() {
        typealias Usage = AudioHardwareIOProcStreamUsage
        guard let proc = procID,
              let flagsOffset = MemoryLayout<Usage>.offset(of: \.mStreamIsOn),
              let countOffset = MemoryLayout<Usage>.offset(of: \.mNumberStreams),
              let total = try? aggregateID.readArray(kAudioDevicePropertyStreams,
                                                     scope: kAudioObjectPropertyScopeInput,
                                                     of: AudioStreamID.self).count,
              total > state.inputSkip else { return }
        let size = flagsOffset + total * MemoryLayout<UInt32>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<Usage>.alignment)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(total), toByteOffset: countOffset, as: UInt32.self)
        for i in 0..<total {
            raw.storeBytes(of: i < state.inputSkip ? 0 : 1, toByteOffset: flagsOffset + 4 * i, as: UInt32.self)
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(size), raw)
    }

    /// Real-time IO callback. No allocation, locks, logging, or ObjC; touches only `state`.
    private static func render(_ state: IOState,
                               input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>) {
        let target = Float(bitPattern: state.target.load(ordering: .relaxed))
        let start = Float(bitPattern: state.applied.load(ordering: .relaxed))
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let first = min(state.inputSkip, inList.count)  // tap buffers are first..<inList.count

        var inChannels = 0, hasNilInput = false, frames = Int.max
        for i in first..<inList.count {
            let b = inList[i]
            let n = Int(b.mNumberChannels)
            inChannels += n
            if b.mData == nil { hasNilInput = true }
            if n > 0 { frames = min(frames, Int(b.mDataByteSize) / (4 * n)) }
        }
        for i in 0..<outList.count {
            let b = outList[i]
            let n = Int(b.mNumberChannels)
            if n > 0, b.mData != nil { frames = min(frames, Int(b.mDataByteSize) / (4 * n)) }
        }
        if hasNilInput || inChannels == 0 || frames == 0 || frames == Int.max {
            for i in 0..<outList.count {
                let b = outList[i]
                if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
            }
            state.applied.store(target.bitPattern, ordering: .relaxed)
            return
        }

        let step = (target - start) / Float(frames)
        let boosting = target > 1 || start > 1
        var k = 0
        for i in 0..<outList.count {
            let ob = outList[i]
            let oc = Int(ob.mNumberChannels)
            guard oc > 0, let od = ob.mData else { k += oc; continue }
            let out = od.assumingMemoryBound(to: Float.self)
            let outFrames = Int(ob.mDataByteSize) / (4 * oc)
            for sub in 0..<oc {
                if let src = lane(inList, from: first, k % inChannels) {
                    if boosting {
                        for f in 0..<frames {
                            out[f * oc + sub] = softLimit(src.base[f * src.stride + src.offset] * (start + step * Float(f + 1)))
                        }
                    } else {
                        for f in 0..<frames {
                            out[f * oc + sub] = src.base[f * src.stride + src.offset] * (start + step * Float(f + 1))
                        }
                    }
                } else {
                    for f in 0..<frames { out[f * oc + sub] = 0 }
                }
                if outFrames > frames { for f in frames..<outFrames { out[f * oc + sub] = 0 } }
                k += 1
            }
        }
        state.applied.store(target.bitPattern, ordering: .relaxed)
    }

    /// Boost only: transparent below 0.9, then rounds peaks off toward ±1 instead of hard clipping.
    @inline(__always)
    private static func softLimit(_ x: Float) -> Float {
        let threshold: Float = 0.9
        let magnitude = abs(x)
        guard magnitude > threshold else { return x }
        let limited = threshold + (1 - threshold) * tanhf((magnitude - threshold) / (1 - threshold))
        return x < 0 ? -limited : limited
    }

    /// Maps a flat tap-channel index (counting buffers from `first`) to its base pointer, interleave stride and offset.
    @inline(__always)
    private static func lane(_ list: UnsafeMutableAudioBufferListPointer, from first: Int, _ channel: Int)
        -> (base: UnsafeMutablePointer<Float>, stride: Int, offset: Int)? {
        var c = channel
        for i in first..<list.count {
            let b = list[i]
            let n = Int(b.mNumberChannels)
            if c < n {
                return b.mData.map { ($0.assumingMemoryBound(to: Float.self), n, c) }
            }
            c -= n
        }
        return nil
    }
}
