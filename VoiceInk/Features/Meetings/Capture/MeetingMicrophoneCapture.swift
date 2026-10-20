import AVFoundation
import CoreAudio
import Foundation
import os

final class MeetingMicrophoneCapture: @unchecked Sendable {
    typealias Handler = ([Float], Double, UInt64) -> Void

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.meeting.microphone")
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCapture")
    private let handler: Handler
    private let onProblem: @Sendable (String) -> Void
    private var restartProblem: String?
    private var configurationObserver: NSObjectProtocol?
    private var active = false

    init(handler: @escaping Handler, onProblem: @escaping @Sendable (String) -> Void = { _ in }) {
        self.handler = handler
        self.onProblem = onProblem
    }

    var problem: String? { queue.sync { restartProblem } }

    func prepare(deviceID: AudioDeviceID?) throws -> Double {
        try queue.sync {
            if let deviceID {
                guard let audioUnit = engine.inputNode.audioUnit else { throw CaptureError.inputUnavailable }
                var selectedDevice = deviceID
                let status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                                  kAudioUnitScope_Global, 0, &selectedDevice,
                                                  UInt32(MemoryLayout<AudioDeviceID>.size))
                guard status == noErr else { throw CaptureError.coreAudio(status) }
            }
            let rate = engine.inputNode.outputFormat(forBus: 0).sampleRate
            guard rate > 0 else { throw CaptureError.inputUnavailable }
            return rate
        }
    }

    func start() throws {
        try queue.sync {
            try installTapAndStart()
            active = true
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, self.active else { return }
                    do {
                        self.engine.stop()
                        self.engine.inputNode.removeTap(onBus: 0)
                        try self.installTapAndStart()
                    } catch {
                        let message = "Microphone capture stopped after an audio configuration change (\(error.localizedDescription))."
                        self.restartProblem = self.restartProblem ?? message
                        self.logger.error("Microphone restart failed: \(error.localizedDescription, privacy: .public)")
                        self.onProblem(message)
                    }
                }
            }
        }
    }

    func stop() {
        queue.sync {
            guard active else { return }
            active = false
            if let configurationObserver {
                NotificationCenter.default.removeObserver(configurationObserver)
                self.configurationObserver = nil
            }
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
    }

    private func installTapAndStart() throws {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.inputUnavailable }
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [handler] buffer, time in
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            var mono = [Float](repeating: 0, count: frames)
            if let channels = buffer.floatChannelData {
                let count = Int(buffer.format.channelCount)
                for channel in 0..<count {
                    let source = channels[channel]
                    for frame in 0..<frames { mono[frame] += source[frame] / Float(count) }
                }
            } else if let channels = buffer.int16ChannelData {
                let count = Int(buffer.format.channelCount)
                for channel in 0..<count {
                    let source = channels[channel]
                    for frame in 0..<frames { mono[frame] += Float(source[frame]) / (32768 * Float(count)) }
                }
            } else {
                return
            }
            handler(mono, buffer.format.sampleRate, time.isHostTimeValid ? time.hostTime : 0)
        }
        try engine.start()
    }

    private enum CaptureError: LocalizedError {
        case inputUnavailable
        case coreAudio(OSStatus)
        var errorDescription: String? {
            switch self {
            case .inputUnavailable: return "The microphone input is unavailable."
            case .coreAudio(let status): return "Could not select the microphone (Core Audio status \(status))."
            }
        }
    }
}
