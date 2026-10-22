import AVFoundation
import CoreAudio
import Foundation
import os
import Synchronization

final class SystemAudioTap: @unchecked Sendable {
    typealias Handler = ([Float], Double, UInt64) -> Void

    private final class Slot: @unchecked Sendable {
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
        var frameCount = 0
        var sampleRate = 0.0
        var hostTime: UInt64 = 0
        var sequence: UInt64 = 0
        var filled = false
        deinit { samples.deallocate() }
    }

    private struct PoolState: @unchecked Sendable {
        var slots = (0..<64).map { _ in Slot() }
        var writeCursor = 0
        var nextSequence: UInt64 = 0
        var droppedBlocks: UInt64 = 0
        var problem: String?
    }

    private let queue = DispatchQueue(label: "com.ashadmohammed.voicer.meeting.system-audio")
    // The IOProc gets its own queue: AudioDeviceStop, called on `queue`, waits for the IO cycle to finish,
    // so running the IO block on `queue` too would deadlock on stop and on an output-device rebuild.
    private let ioQueue = DispatchQueue(label: "com.ashadmohammed.voicer.meeting.system-audio.io", qos: .userInteractive)
    private let logger = Logger(subsystem: "com.ashadmohammed.voicer", category: "MeetingCapture")
    private let handler: Handler
    private let onProblem: @Sendable (String) -> Void
    private let pool = OSAllocatedUnfairLock(initialState: PoolState())
    private var drainTimer: DispatchSourceTimer?
    private let contentionDrops = Atomic<Int>(0)
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat = AudioStreamBasicDescription()
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var running = false

    init(handler: @escaping Handler, onProblem: @escaping @Sendable (String) -> Void = { _ in }) {
        self.handler = handler
        self.onProblem = onProblem
    }

    var droppedBlockCount: UInt64 {
        pool.withLock { $0.droppedBlocks } + UInt64(max(0, contentionDrops.load(ordering: .relaxed)))
    }
    var problem: String? { queue.sync { pool.withLock { $0.problem } } }

    func prepare() throws -> Double {
        try queue.sync {
            try createTapAndDevice()
            return tapFormat.mSampleRate
        }
    }

    func start() throws {
        try queue.sync {
            try startIOProc()
            running = true
            installOutputListener()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.drainSlots() }
            drainTimer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            running = false
            removeOutputListener()
            tearDownDeviceAndTap()
            drainTimer?.cancel()
            drainTimer = nil
            drainSlots()
        }
    }

    private func createTapAndDevice() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcessObjects())
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "Voicer Meeting Capture"
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.coreAudio("create process tap", status) }

        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &tapFormat)
        guard status == noErr else {
            tearDownDeviceAndTap()
            throw TapError.coreAudio("read tap format", status)
        }

        let tapEntry: [[String: Any]] = [[
            kAudioSubTapUIDKey: description.uuid.uuidString,
            kAudioSubTapDriftCompensationKey: true
        ]]
        var aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Voicer Meeting Capture",
            kAudioAggregateDeviceUIDKey: "com.ashadmohammed.voicer.meeting-tap.\(description.uuid.uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: tapEntry
        ]

        if let output = defaultOutputDevice(), let outputUID = deviceUID(output) {
            aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        if status != noErr, aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] != nil {
            logger.error("Aggregate with output device failed (Core Audio status \(status)); retrying tap-only")
            aggregateDescription.removeValue(forKey: kAudioAggregateDeviceMainSubDeviceKey)
            aggregateDescription.removeValue(forKey: kAudioAggregateDeviceSubDeviceListKey)
            aggregateID = kAudioObjectUnknown
            status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        }
        guard status == noErr else {
            tearDownDeviceAndTap()
            throw TapError.coreAudio("create aggregate device", status)
        }

    }

    private func startIOProc() throws {
        var status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { [weak self] _, inputData, inputTime, _, _ in
            guard let self else { return }
            self.copyInput(inputData, hostTime: inputTime.pointee.mHostTime)
        }
        guard status == noErr else {
            tearDownDeviceAndTap()
            throw TapError.coreAudio("create audio IO procedure", status)
        }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            tearDownDeviceAndTap()
            throw TapError.coreAudio("start aggregate device", status)
        }
    }

    private func copyInput(_ input: UnsafePointer<AudioBufferList>, hostTime: UInt64) {
        let acquired = pool.withLockIfAvailableUnchecked { state -> Bool in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let channels = max(1, Int(tapFormat.mChannelsPerFrame))
            let bytesPerSample = Int(tapFormat.mBitsPerChannel / 8)
            guard bytesPerSample > 0, !list.isEmpty else { return true }
            let nonInterleaved = (tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            let isFloat = (tapFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            let frames: Int
            if nonInterleaved {
                frames = Int(list[0].mDataByteSize) / bytesPerSample
            } else {
                frames = Int(list[0].mDataByteSize) / (bytesPerSample * channels)
            }
            guard frames > 0 else { return true }
            var slotIndex = -1
            for offset in 0..<state.slots.count {
                let index = (state.writeCursor + offset) % state.slots.count
                if !state.slots[index].filled { slotIndex = index; break }
            }
            guard slotIndex >= 0 else {
                state.droppedBlocks += 1
                return true
            }
            let slot = state.slots[slotIndex]
            let copiedFrames = min(frames, 8192)
            if frames > copiedFrames { state.droppedBlocks += 1 }
            for frame in 0..<copiedFrames {
                var sum: Float = 0
                for channel in 0..<channels {
                    let bufferIndex = nonInterleaved ? channel : 0
                    guard bufferIndex < list.count, let data = list[bufferIndex].mData else { continue }
                    let sampleIndex = nonInterleaved ? frame : frame * channels + channel
                    let pointer = data.advanced(by: sampleIndex * bytesPerSample)
                    let value: Float
                    if isFloat && bytesPerSample == 4 {
                        value = pointer.load(as: Float.self)
                    } else if bytesPerSample == 2 {
                        value = Float(pointer.load(as: Int16.self)) / 32768
                    } else if bytesPerSample == 4 {
                        value = Float(pointer.load(as: Int32.self)) / 2_147_483_648
                    } else {
                        value = 0
                    }
                    sum += value
                }
                slot.samples[frame] = sum / Float(channels)
            }
            slot.frameCount = copiedFrames
            slot.sampleRate = tapFormat.mSampleRate
            slot.hostTime = hostTime
            slot.sequence = state.nextSequence
            state.nextSequence &+= 1
            slot.filled = true
            state.writeCursor = (slotIndex + 1) % state.slots.count
            return true
        }
        if acquired == nil { contentionDrops.wrappingAdd(1, ordering: .relaxed) }
    }

    /// Hands filled slots to the writer. The lock is held only to find and then release slots, never while
    /// copying, so the audio thread's try-lock almost never misses. A slot marked filled is left alone by the
    /// audio thread, so reading it outside the lock is safe.
    private func drainSlots() {
        var ready: [Slot] = []
        ready.reserveCapacity(64)
        pool.withLockUnchecked { state in
            for slot in state.slots where slot.filled { ready.append(slot) }
        }
        guard !ready.isEmpty else { return }
        ready.sort { $0.sequence < $1.sequence }
        for slot in ready {
            handler(Array(UnsafeBufferPointer(start: slot.samples, count: slot.frameCount)), slot.sampleRate, slot.hostTime)
        }
        pool.withLockUnchecked { _ in
            for slot in ready {
                slot.frameCount = 0
                slot.filled = false
            }
        }
    }

    private func ownProcessObjects() -> [AudioObjectID] {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var processObject = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processObject)
        guard status == noErr, processObject != kAudioObjectUnknown else {
            logger.error("Could not resolve this process for tap exclusion (Core Audio status \(status)); excluding none")
            return []
        }
        return [processObject]
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private func deviceUID(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private func installOutputListener() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            self.tearDownDeviceAndTap()
            do {
                try self.createTapAndDevice()
                try self.startIOProc()
            }
            catch {
                let message = "Call audio stopped after the output device changed (\(error.localizedDescription))."
                self.pool.withLock { $0.problem = $0.problem ?? message }
                self.logger.error("Could not rebuild system audio capture: \(error.localizedDescription, privacy: .public)")
                self.onProblem(message)
            }
        }
        outputListener = listener
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        if status != noErr {
            outputListener = nil
            logger.error("Could not listen for output changes (Core Audio status \(status))")
        }
    }

    private func removeOutputListener() {
        guard let outputListener else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, outputListener)
        if status != noErr { logger.error("Could not remove output listener (Core Audio status \(status))") }
        self.outputListener = nil
    }

    private func tearDownDeviceAndTap() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                let stopStatus = AudioDeviceStop(aggregateID, ioProcID)
                if stopStatus != noErr { logger.error("Could not stop aggregate device (Core Audio status \(stopStatus))") }
                let destroyStatus = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                if destroyStatus != noErr { logger.error("Could not destroy audio IO procedure (Core Audio status \(destroyStatus))") }
                self.ioProcID = nil
            }
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status != noErr { logger.error("Could not destroy aggregate device (Core Audio status \(status))") }
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr { logger.error("Could not destroy process tap (Core Audio status \(status))") }
            tapID = kAudioObjectUnknown
        }
    }

    private enum TapError: LocalizedError {
        case coreAudio(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .coreAudio(let operation, let status): return "Could not \(operation) (Core Audio status \(status))."
            }
        }
    }
}
