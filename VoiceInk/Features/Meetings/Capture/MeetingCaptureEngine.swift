import CoreAudio
import AVFoundation
import AppKit
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

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A meeting recording is already in progress."
        }
    }
}

@MainActor
final class MeetingCaptureEngine {
    var onProblem: (@MainActor (String?) -> Void)?
    var onDeviceNotice: (@MainActor (String?) -> Void)?
    private(set) var isRecording = false
    private(set) var isPaused = false
    var microphoneLevel: Float { microphoneSink.level }
    var callLevel: Float { callSink.level }
    var microphoneSpeechLevel: Float { microphoneSink.speechLevel }
    var callSpeechLevel: Float { callSink.speechLevel }

    private let logger = Logger(subsystem: "com.ashadmohammed.voicer", category: "MeetingCapture")
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
    private var pausedAtHostTime: UInt64 = 0
    private var warnings: [String] = []
    private var lastResult: MeetingCaptureResult?
    private var microphoneProblem: String?
    private var callProblem: String?
    private var microphoneWriteProblem: String?
    private var callWriteProblem: String?
    private var watchdogTask: Task<Void, Never>?
    private var microphonePermissionRetryTask: Task<Void, Never>?
    private var microphonePermissionRequestedSession: UInt64?
    private var microphoneDeviceID: AudioDeviceID?
    private var microphoneDeviceUID: String?
    private var followsSystemDefaultInput = false
    private var captureSessionID: UInt64 = 0
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var watchdogGraceUntil = Date.distantPast
    private var sleepWatchdogGracePending = false
    private var sleepWatchdogGraceStartedAt: Date?

    init() {}

    func start(
        folder: URL,
        microphoneDeviceID: AudioDeviceID?,
        microphoneDeviceUID: String? = nil,
        followsSystemDefaultInput: Bool = false
    ) throws {
        guard !isRecording else { throw MeetingCaptureError.alreadyRecording }
        captureSessionID &+= 1
        let sessionID = captureSessionID
        self.microphoneDeviceID = microphoneDeviceID
        self.microphoneDeviceUID = microphoneDeviceUID
        self.followsSystemDefaultInput = followsSystemDefaultInput
        isRecording = true
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
        microphoneProblem = nil
        callProblem = nil
        microphoneWriteProblem = nil
        callWriteProblem = nil
        startedAt = Date()
        isPaused = false
        watchdogGraceUntil = .distantPast
        sleepWatchdogGracePending = false
        sleepWatchdogGraceStartedAt = nil
        observeSystemSleep()
        microphoneSink.resume(at: 0)
        callSink.resume(at: 0)
        sessionHostTime = mach_absolute_time()

        let microphoneURL = folder.appendingPathComponent("microphone.caf")
        do {
            let writer = try MeetingTrackWriter(
                url: microphoneURL, sampleRate: 48_000, sessionHostTime: sessionHostTime, label: "microphone",
                onProblem: { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrentSession(sessionID) else { return }
                        self.setWriteProblem(message, for: .microphone)
                    }
                })
            microphoneWriter = writer
            microphoneSink.set(writer)
            self.microphoneURL = microphoneURL
        } catch {
            let message = "Microphone audio could not be saved."
            warnings.append("\(message) (\(error.localizedDescription))")
            setProblem(message, for: .microphone)
            logger.error("\(message, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        let callURL = folder.appendingPathComponent("call.caf")
        do {
            let writer = try MeetingTrackWriter(
                url: callURL, sampleRate: 48_000, sessionHostTime: sessionHostTime, label: "call",
                onProblem: { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrentSession(sessionID) else { return }
                        self.setWriteProblem(message, for: .call)
                    }
                })
            callWriter = writer
            callSink.set(writer)
            self.callURL = callURL
        } catch {
            let message = "Call audio could not be saved."
            warnings.append("\(message) (\(error.localizedDescription))")
            setProblem(message, for: .call)
            logger.error("\(message, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        if microphoneWriter != nil {
            startMicrophoneIfAuthorized(sessionID: sessionID)
        }

        if callWriter != nil {
            let callSink = self.callSink
            let tap = SystemAudioTap(
                handler: { samples, rate, hostTime in
                    callSink.enqueue(samples, sampleRate: rate, hostTime: hostTime)
                },
                onProblem: { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrentSession(sessionID) else { return }
                        if message != nil, Date() < self.watchdogGraceUntil { return }
                        self.setProblem(message, for: .call)
                    }
                })
            systemTap = tap
            tap.start()
        }

        startWatchdog()
    }

    /// Stops both tracks together. Time spent paused is left out of both files, so they stay in step.
    func pause() {
        guard isRecording, !isPaused else { return }
        pausedAtHostTime = mach_absolute_time()
        isPaused = true
        microphoneSink.pause()
        callSink.pause()
    }

    func resume() {
        guard isRecording, isPaused else { return }
        let now = mach_absolute_time()
        let gap = now > pausedAtHostTime ? now - pausedAtHostTime : 0
        microphoneWriter?.skipPausedTime(ticks: gap)
        callWriter?.skipPausedTime(ticks: gap)
        microphoneSink.resume(at: now)
        callSink.resume(at: now)
        isPaused = false
    }

    func stop() async -> MeetingCaptureResult {
        if let lastResult { return lastResult }
        guard isRecording else {
            return MeetingCaptureResult(microphoneURL: nil, callURL: nil, startedAt: startedAt,
                                        duration: 0, warnings: warnings)
        }

        isRecording = false
        captureSessionID &+= 1
        microphonePermissionRetryTask?.cancel()
        microphonePermissionRetryTask = nil
        microphonePermissionRequestedSession = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        removeSystemSleepObservers()
        systemTap?.stop()
        microphone?.stop()
        callWriter?.finish()
        microphoneWriter?.finish()

        if let problem = systemTap?.problem { warnings.append(problem) }
        if let problem = microphone?.problem { warnings.append(problem) }
        if let microphoneProblem, microphoneProblem.hasPrefix("The microphone is sending silence") {
            warnings.append(microphoneProblem)
        }
        if let problem = callWriter?.problem { warnings.append(problem) }
        if let problem = microphoneWriter?.problem { warnings.append(problem) }
        if let systemTap, systemTap.droppedBlockCount > 0 {
            warnings.append("Some call audio was dropped because the Mac was busy (\(systemTap.droppedBlockCount) short gaps).")
        }

        let hasMicrophoneAudio = (microphoneWriter?.receivedFrameCount ?? 0) > 0
        let hasCallAudio = (callWriter?.receivedFrameCount ?? 0) > 0
        if !hasMicrophoneAudio {
            warnings.append("Microphone audio was not recorded.")
            if let microphoneURL { try? FileManager.default.removeItem(at: microphoneURL) }
        }
        if !hasCallAudio {
            warnings.append("Call audio was not recorded.")
            if let callURL { try? FileManager.default.removeItem(at: callURL) }
        }

        let micDuration = Double(microphoneWriter?.frameCount ?? 0) / (microphoneWriter?.sampleRate ?? 1)
        let callDuration = Double(callWriter?.frameCount ?? 0) / (callWriter?.sampleRate ?? 1)
        let result = MeetingCaptureResult(
            microphoneURL: hasMicrophoneAudio ? microphoneURL : nil,
            callURL: hasCallAudio ? callURL : nil,
            startedAt: startedAt,
            duration: max(micDuration, callDuration),
            warnings: warnings.reduce(into: []) { result, warning in
                if !result.contains(warning) { result.append(warning) }
            })
        microphoneWriter = nil
        callWriter = nil
        microphoneSink.set(nil)
        callSink.set(nil)
        microphone = nil
        systemTap = nil
        isPaused = false
        microphoneProblem = nil
        callProblem = nil
        microphoneWriteProblem = nil
        callWriteProblem = nil
        sleepWatchdogGracePending = false
        sleepWatchdogGraceStartedAt = nil
        onProblem?(nil)
        onDeviceNotice?(nil)
        lastResult = result
        return result
    }

    private func isCurrentSession(_ sessionID: UInt64) -> Bool {
        isRecording && captureSessionID == sessionID
    }

    private func startMicrophoneIfAuthorized(sessionID: UInt64) {
        guard isCurrentSession(sessionID), microphone == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphonePermissionRetryTask?.cancel()
            microphonePermissionRetryTask = nil
            let micSink = microphoneSink
            let micCapture = MeetingMicrophoneCapture(
                handler: { samples, rate, hostTime in
                    micSink.enqueue(samples, sampleRate: rate, hostTime: hostTime)
                },
                onProblem: { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrentSession(sessionID) else { return }
                        if message != nil, Date() < self.watchdogGraceUntil { return }
                        self.setProblem(message, for: .microphone)
                    }
                },
                onDeviceNotice: { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrentSession(sessionID) else { return }
                        self.onDeviceNotice?(message)
                    }
                },
                onRestart: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrentSession(sessionID) else { return }
                        micSink.resetWatchdogTimers()
                        self.sleepWatchdogGraceStartedAt = Date()
                        self.sleepWatchdogGracePending = true
                        self.watchdogGraceUntil = Date().addingTimeInterval(5)
                    }
                })
            microphone = micCapture
            micCapture.start(
                preferredDeviceID: microphoneDeviceID,
                preferredDeviceUID: microphoneDeviceUID,
                followsSystemDefaultInput: followsSystemDefaultInput
            )
        case .notDetermined:
            showMicrophonePermissionProblem()
            scheduleMicrophonePermissionRetry(sessionID: sessionID)
            guard microphonePermissionRequestedSession != sessionID else { return }
            microphonePermissionRequestedSession = sessionID
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentSession(sessionID) else { return }
                    self.startMicrophoneIfAuthorized(sessionID: sessionID)
                }
            }
        case .denied, .restricted:
            showMicrophonePermissionProblem()
            scheduleMicrophonePermissionRetry(sessionID: sessionID)
        @unknown default:
            showMicrophonePermissionProblem()
            scheduleMicrophonePermissionRetry(sessionID: sessionID)
        }
    }

    private func showMicrophonePermissionProblem() {
        setProblem(
            "Voicer isn't allowed to use the microphone. Allow it in System Settings > Privacy & Security > Microphone.",
            for: .microphone
        )
    }

    private func scheduleMicrophonePermissionRetry(sessionID: UInt64) {
        guard microphonePermissionRetryTask == nil else { return }
        microphonePermissionRetryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled,
                      let self,
                      self.isCurrentSession(sessionID),
                      self.microphone == nil else { break }
                if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                    self.startMicrophoneIfAuthorized(sessionID: sessionID)
                    return
                }
            }
            guard let self, self.captureSessionID == sessionID else { return }
            self.microphonePermissionRetryTask = nil
        }
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isRecording, !self.isPaused else { continue }
                self.checkTrack(.microphone, sink: self.microphoneSink, startedAt: self.startedAt)
                self.checkTrack(.call, sink: self.callSink, startedAt: self.startedAt)
            }
        }
    }

    private func checkTrack(_ track: Track, sink: MeetingTrackSink, startedAt: Date) {
        if sleepWatchdogGracePending,
           let graceStartedAt = sleepWatchdogGraceStartedAt,
           let elapsed = sink.secondsSinceLastFrame,
           Date().addingTimeInterval(-elapsed) > graceStartedAt {
            sleepWatchdogGracePending = false
            sleepWatchdogGraceStartedAt = nil
            watchdogGraceUntil = Date().addingTimeInterval(5)
        }
        guard Date() >= watchdogGraceUntil else { return }
        if track == .microphone, microphone == nil { return }
        if track == .call, systemTap == nil { return }
        let problem = track == .microphone ? microphoneProblem : callProblem
        if track == .microphone {
            let silenceMessage = "The microphone is sending silence. Check it isn't muted, and that Voicer is allowed to use it."
            let elapsedSinceFrame = sink.secondsSinceLastFrame ?? .greatestFiniteMagnitude
            if let silenceDuration = sink.secondsSinceSilenceStarted,
               silenceDuration >= 4,
               elapsedSinceFrame < 4
            {
                setProblem(silenceMessage, for: .microphone)
                return
            }
            if problem == silenceMessage {
                if elapsedSinceFrame >= 4 {
                    setProblem("Microphone is not picking anything up", for: .microphone)
                    return
                }
                guard sink.hasNonZeroSamplesSinceProblem else { return }
                setProblem(nil, for: .microphone)
                return
            }
        }
        if problem != nil {
            // A frame from before the failure must not clear the warning; wait for audio that
            // actually arrives after it was raised.
            guard sink.hasFramesSinceProblem else { return }
            let elapsed = sink.secondsSinceLastFrame ?? .greatestFiniteMagnitude
            guard elapsed < 4 else { return }
            setProblem(nil, for: track)
            return
        }
        let elapsed = sink.secondsSinceLastFrame ?? Date().timeIntervalSince(startedAt)
        guard elapsed >= 4 else { return }
        setProblem(track == .microphone
                   ? "Microphone is not picking anything up"
                   : "Call audio is not coming through", for: track)
    }

    private func setProblem(_ message: String?, for track: Track) {
        let previous = combinedProblem
        switch track {
        case .microphone:
            if let message {
                if microphoneProblem != message { microphoneSink.markProblem() }
            } else {
                microphoneSink.clearProblemMark()
            }
            microphoneProblem = message
        case .call:
            if let message {
                if callProblem != message { callSink.markProblem() }
            } else {
                callSink.clearProblemMark()
            }
            callProblem = message
        }
        if previous != combinedProblem { onProblem?(combinedProblem) }
    }

    /// A write failure is a fact about the file, not about the last four seconds of audio, so the frame
    /// watchdog must not clear it.
    private func setWriteProblem(_ message: String?, for track: Track) {
        let previous = combinedProblem
        switch track {
        case .microphone:
            microphoneWriteProblem = message
        case .call:
            callWriteProblem = message
        }
        if previous != combinedProblem { onProblem?(combinedProblem) }
    }

    private var combinedProblem: String? {
        let messages = [microphoneProblem, callProblem, microphoneWriteProblem, callWriteProblem].compactMap { $0 }
        guard !messages.isEmpty else { return nil }
        return messages.map { $0.hasSuffix(".") ? $0 : "\($0)." }.joined(separator: " ")
    }

    private func observeSystemSleep() {
        removeSystemSleepObservers()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.microphoneSink.resetWatchdogTimers()
                self.callSink.resetWatchdogTimers()
                let sleepStartedAt = Date()
                self.sleepWatchdogGraceStartedAt = sleepStartedAt
                self.watchdogGraceUntil = sleepStartedAt.addingTimeInterval(30)
                self.sleepWatchdogGracePending = true
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.microphoneSink.resetWatchdogTimers()
                self.callSink.resetWatchdogTimers()
                let wakeStartedAt = Date()
                self.sleepWatchdogGraceStartedAt = wakeStartedAt
                self.watchdogGraceUntil = wakeStartedAt.addingTimeInterval(5)
                self.sleepWatchdogGracePending = true
            }
        }
    }

    private func removeSystemSleepObservers() {
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private enum Track: Equatable {
        case microphone
        case call
    }
}
