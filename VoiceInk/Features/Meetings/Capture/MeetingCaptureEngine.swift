import CoreAudio
import Foundation
import os

struct MeetingCaptureResult: Sendable {
    var microphoneURL: URL?
    var callURL: URL?
    var startedAt: Date
    var duration: TimeInterval
    var warnings: [String]
}

enum MeetingCaptureError: LocalizedError {
    case alreadyRecording
    case nothingCouldStart(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A meeting recording is already in progress."
        case .nothingCouldStart(let reason): return reason
        }
    }
}

@MainActor
final class MeetingCaptureEngine {
    private(set) var isRecording = false
    var microphoneLevel: Float { microphoneSink.level }
    var callLevel: Float { callSink.level }

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCapture")
    private let microphoneSink = MeetingTrackSink()
    private let callSink = MeetingTrackSink()
    private var microphone: MeetingMicrophoneCapture?
    private var systemTap: SystemAudioTap?
    private var microphoneWriter: MeetingTrackWriter?
    private var callWriter: MeetingTrackWriter?
    private var microphoneURL: URL?
    private var callURL: URL?
    private var startedAt = Date()
    private var sessionHostTime: UInt64 = 0
    private var warnings: [String] = []
    private var lastResult: MeetingCaptureResult?

    init() {}

    func start(folder: URL, microphoneDeviceID: AudioDeviceID?) throws {
        guard !isRecording else { throw MeetingCaptureError.alreadyRecording }
        warnings = []
        lastResult = nil
        microphone = nil
        systemTap = nil
        microphoneWriter = nil
        callWriter = nil
        microphoneSink.set(nil)
        callSink.set(nil)
        microphoneURL = nil
        callURL = nil
        startedAt = Date()
        sessionHostTime = mach_absolute_time()

        let micURL = folder.appendingPathComponent("microphone.caf")
        let micSink = microphoneSink
        let micCapture = MeetingMicrophoneCapture { samples, rate, hostTime in
            micSink.enqueue(samples, sampleRate: rate, hostTime: hostTime)
        }
        do {
            let rate = try micCapture.prepare(deviceID: microphoneDeviceID)
            let writer = try MeetingTrackWriter(url: micURL, sampleRate: rate,
                                                sessionHostTime: sessionHostTime, label: "microphone")
            microphone = micCapture
            microphoneWriter = writer
            microphoneSink.set(writer)
            try micCapture.start()
            microphoneURL = micURL
        } catch {
            micCapture.stop()
            microphoneWriter?.finish()
            microphoneWriter = nil
            microphoneSink.set(nil)
            try? FileManager.default.removeItem(at: micURL)
            let warning = "Microphone couldn't be recorded (\(error.localizedDescription))."
            warnings.append(warning)
            logger.error("\(warning, privacy: .public)")
        }

        let callSink = self.callSink
        let tap = SystemAudioTap { samples, rate, hostTime in
            callSink.enqueue(samples, sampleRate: rate, hostTime: hostTime)
        }
        do {
            let rate = try tap.prepare()
            let url = folder.appendingPathComponent("call.caf")
            let writer = try MeetingTrackWriter(url: url, sampleRate: rate,
                                                sessionHostTime: sessionHostTime, label: "call")
            callWriter = writer
            callSink.set(writer)
            try tap.start()
            systemTap = tap
            callURL = url
        } catch {
            tap.stop()
            callWriter?.finish()
            callWriter = nil
            callSink.set(nil)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("call.caf"))
            let warning = "System audio couldn't be recorded (\(error.localizedDescription))."
            warnings.append(warning)
            logger.error("\(warning, privacy: .public)")
        }

        guard microphoneURL != nil || callURL != nil else {
            throw MeetingCaptureError.nothingCouldStart(warnings.joined(separator: " "))
        }
        isRecording = true
    }

    func stop() async -> MeetingCaptureResult {
        if let lastResult { return lastResult }
        guard isRecording else {
            return MeetingCaptureResult(microphoneURL: nil, callURL: nil, startedAt: startedAt,
                                        duration: 0, warnings: warnings)
        }

        systemTap?.stop()
        microphone?.stop()
        callWriter?.finish()
        microphoneWriter?.finish()

        let micDuration = Double(microphoneWriter?.frameCount ?? 0) / (microphoneWriter?.sampleRate ?? 1)
        let callDuration = Double(callWriter?.frameCount ?? 0) / (callWriter?.sampleRate ?? 1)
        let result = MeetingCaptureResult(microphoneURL: microphoneURL, callURL: callURL,
                                          startedAt: startedAt, duration: max(micDuration, callDuration),
                                          warnings: warnings)
        microphoneWriter = nil
        callWriter = nil
        microphoneSink.set(nil)
        callSink.set(nil)
        microphone = nil
        systemTap = nil
        isRecording = false
        lastResult = result
        return result
    }
}
