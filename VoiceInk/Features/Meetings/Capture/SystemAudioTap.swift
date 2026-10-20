import AVFoundation
import CoreAudio
import Foundation
import os

final class SystemAudioTap: @unchecked Sendable {
    typealias Handler = ([Float], Double, UInt64) -> Void

    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.meeting.system-audio")
    // The IOProc gets its own queue: AudioDeviceStop, called on `queue`, waits for the IO cycle to finish,
    // so running the IO block on `queue` too would deadlock on stop and on an output-device rebuild.
    private let ioQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.meeting.system-audio.io", qos: .userInteractive)
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCapture")
    private let handler: Handler
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat = AudioStreamBasicDescription()
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var running = false

    init(handler: @escaping Handler) { self.handler = handler }

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
        }
    }

    func stop() {
        queue.sync {
            running = false
            removeOutputListener()
            tearDownDeviceAndTap()
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
            kAudioAggregateDeviceUIDKey: "com.prakashjoshipax.voiceink.meeting-tap.\(description.uuid.uuidString)",
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
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let channels = max(1, Int(tapFormat.mChannelsPerFrame))
        let bytesPerSample = Int(tapFormat.mBitsPerChannel / 8)
        guard bytesPerSample > 0, !list.isEmpty else { return }
        let nonInterleaved = (tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isFloat = (tapFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let frames: Int
        if nonInterleaved {
            frames = Int(list[0].mDataByteSize) / bytesPerSample
        } else {
            frames = Int(list[0].mDataByteSize) / (bytesPerSample * channels)
        }
        guard frames > 0 else { return }
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
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
            mono[frame] = sum / Float(channels)
        }
        handler(mono, tapFormat.mSampleRate, hostTime)
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
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value as String
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
            catch { self.logger.error("Could not rebuild system audio capture: \(error.localizedDescription, privacy: .public)") }
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
