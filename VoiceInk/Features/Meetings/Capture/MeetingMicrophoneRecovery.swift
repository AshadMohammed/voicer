import Foundation

// Pieces the capture engine uses to survive a microphone capture whose queue got stuck inside AVAudioEngine
// (seen on 13 Nov: after a configuration change nothing on that queue ever ran again, and the mic track ended
// 14 minutes into a 45 minute meeting while the call track carried on).

/// Carries one microphone capture's frames to the mic track, for as long as that capture is the live one.
/// Closing it is how an abandoned capture is unhooked: anything it still delivers afterwards is ignored.
final class MeetingMicrophoneRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: MeetingTrackSink
    private let gaps: MeetingMicrophoneGapLog
    private let patchesMissingHostTime: Bool
    private let onFirstFrame: @Sendable () -> Void
    private let timebase: mach_timebase_info_data_t
    private var isOpen = true
    private var hasDelivered = false

    /// `patchesMissingHostTime` is for a replacement capture: its first buffer must carry a clock time, or the track
    /// writer would join it straight onto the end of the old audio instead of filling the gap with silence.
    init(
        sink: MeetingTrackSink,
        gaps: MeetingMicrophoneGapLog,
        patchesMissingHostTime: Bool,
        onFirstFrame: @escaping @Sendable () -> Void
    ) {
        self.sink = sink
        self.gaps = gaps
        self.patchesMissingHostTime = patchesMissingHostTime
        self.onFirstFrame = onFirstFrame
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        self.timebase = timebase
    }

    func deliver(_ samples: [Float], sampleRate: Double, hostTime: UInt64) {
        lock.lock()
        let open = isOpen
        let first = open && !hasDelivered
        if first { hasDelivered = true }
        lock.unlock()
        guard open else { return }

        var time = hostTime
        if first, time == 0, patchesMissingHostTime, sampleRate > 0 {
            // The buffer ended about now; it started one buffer length earlier.
            let nanos = Double(samples.count) / sampleRate * 1_000_000_000
            let ticks = UInt64(nanos * Double(timebase.denom) / Double(timebase.numer))
            let now = mach_absolute_time()
            time = now > ticks ? now - ticks : now
        }
        gaps.note(hostTime: time)
        sink.enqueue(samples, sampleRate: sampleRate, hostTime: time)
        if first { onFirstFrame() }
    }

    func close() {
        lock.lock()
        isOpen = false
        lock.unlock()
    }
}

/// Notes stretches of the meeting in which no microphone audio arrived. The track writer fills such a stretch with
/// silence from the frames' clock times, so the position of each gap here is where it sits in the saved file.
final class MeetingMicrophoneGapLog: @unchecked Sendable {
    struct Gap: Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
    }

    /// Shorter breaks (a headset switching, a format change) are ordinary and not worth telling the reader about.
    static let minimumGap: TimeInterval = 10

    private let lock = NSLock()
    private let sessionHostTime: UInt64
    private let timebase: mach_timebase_info_data_t
    private var pausedTicks: UInt64 = 0
    private var lastHostTime: UInt64 = 0
    private var lastPausedTicks: UInt64 = 0
    private var recorded: [Gap] = []

    init(sessionHostTime: UInt64) {
        self.sessionHostTime = sessionHostTime
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        self.timebase = timebase
    }

    /// Mirrors the track writers: time spent paused is left out of the file, so it is left out of the positions too.
    func addPausedTicks(_ ticks: UInt64) {
        lock.lock()
        pausedTicks += ticks
        lock.unlock()
    }

    func note(hostTime: UInt64) {
        guard hostTime != 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard hostTime > lastHostTime else { return }
        // The first frame of the meeting has nothing before it; the writer pads that start by itself.
        if lastHostTime != 0, seconds(hostTime - lastHostTime) >= Self.minimumGap {
            recorded.append(
                Gap(
                    start: position(of: lastHostTime, pausedTicks: lastPausedTicks),
                    end: position(of: hostTime, pausedTicks: pausedTicks)))
        }
        lastHostTime = hostTime
        lastPausedTicks = pausedTicks
    }

    var gaps: [Gap] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func seconds(_ ticks: UInt64) -> TimeInterval {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    private func position(of hostTime: UInt64, pausedTicks: UInt64) -> TimeInterval {
        let offset = sessionHostTime &+ pausedTicks
        return hostTime > offset ? seconds(hostTime - offset) : 0
    }

    /// "14:45", or "1:05:09" from an hour on.
    static func clockText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

/// Watches the microphone capture from outside its own queue. When no mic audio has arrived for a while, it posts an
/// empty block to the capture's queue; a queue that does not run it within two seconds is stuck. Everything here runs on
/// the monitor's own queue, so a stuck capture can never block it, and nothing here ever waits on the capture.
final class MeetingMicrophoneLivenessMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ashadmohammed.voicer.meeting.microphone.liveness")
    private let secondsSinceFrame: @Sendable () -> TimeInterval?
    private let onWedged: @Sendable (MeetingMicrophoneCapture) -> Void
    private let checkEvery: TimeInterval = 2
    private let quietLimit: TimeInterval = 6
    private let answerLimit: TimeInterval = 2
    private var timer: DispatchSourceTimer?
    private var watched: MeetingMicrophoneCapture?
    private var watchedSince = Date()
    private var graceUntil = Date.distantPast
    private var paused = false
    private var pingToken: UInt64 = 0
    private var pingOutstanding = false

    /// `secondsSinceFrame` says how long ago the mic track last got audio (nil when it never has).
    /// `onWedged` is told once per capture; the owner decides what replaces it and calls `watch` with the replacement.
    init(
        secondsSinceFrame: @escaping @Sendable () -> TimeInterval?,
        onWedged: @escaping @Sendable (MeetingMicrophoneCapture) -> Void
    ) {
        self.secondsSinceFrame = secondsSinceFrame
        self.onWedged = onWedged
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + checkEvery, repeating: checkEvery)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            watched = nil
            pingOutstanding = false
            pingToken &+= 1
        }
    }

    /// The capture to keep an eye on (nil for none). Its silence is counted from now.
    func watch(_ capture: MeetingMicrophoneCapture?) {
        queue.async { [self] in
            watched = capture
            watchedSince = Date()
            pingOutstanding = false
            pingToken &+= 1
        }
    }

    /// While paused no audio reaches the track, so quiet is expected. Counting starts again on resume.
    func setPaused(_ isPaused: Bool) {
        queue.async { [self] in
            paused = isPaused
            watchedSince = Date()
            pingOutstanding = false
            pingToken &+= 1
        }
    }

    /// No checks for a while, for example around sleep and wake, when the capture legitimately takes its time.
    func extendGrace(_ seconds: TimeInterval) {
        queue.async { [self] in
            graceUntil = max(graceUntil, Date().addingTimeInterval(seconds))
            watchedSince = max(watchedSince, Date())
        }
    }

    private func tick() {
        guard !paused, !pingOutstanding, let capture = watched else { return }
        let now = Date()
        guard now >= graceUntil else { return }
        let quiet = min(secondsSinceFrame() ?? .infinity, now.timeIntervalSince(watchedSince))
        guard quiet > quietLimit else { return }

        pingOutstanding = true
        pingToken &+= 1
        let token = pingToken
        capture.ping { [weak self] in
            self?.queue.async { self?.pingAnswered(token) }
        }
        queue.asyncAfter(deadline: .now() + answerLimit) { [weak self] in
            self?.pingExpired(token)
        }
    }

    private func pingAnswered(_ token: UInt64) {
        guard token == pingToken else { return }
        pingOutstanding = false
    }

    private func pingExpired(_ token: UInt64) {
        guard token == pingToken, pingOutstanding, let capture = watched else { return }
        pingOutstanding = false
        // Reported once. Until the owner watches a replacement there is nothing to check.
        watched = nil
        onWedged(capture)
    }
}
