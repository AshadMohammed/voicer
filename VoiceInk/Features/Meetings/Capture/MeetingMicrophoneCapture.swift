import AVFoundation
import AppKit
import CoreAudio
import Foundation
import os

/// Captures the microphone on the first input device that actually works. Device IDs can change after a
/// headset or sleep change, so a saved UID is resolved again whenever the device list changes.
final class MeetingMicrophoneCapture: @unchecked Sendable {
    typealias Handler = ([Float], Double, UInt64) -> Void
    private typealias FrameReceiver = @Sendable (UInt64, [Float], Double, UInt64) -> Void

    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.ashadmohammed.voicer.meeting.microphone")
    private let logger = Logger(subsystem: "com.ashadmohammed.voicer", category: "MeetingCapture")
    private let handler: Handler
    private let onProblem: @Sendable (String?) -> Void
    private let onDeviceNotice: @Sendable (String?) -> Void
    private let onRestart: @Sendable () -> Void
    private var preferredDeviceID: AudioDeviceID?
    private var preferredDeviceUID: String?
    private var followsSystemDefaultInput = false
    private var resolvedPreferredDeviceID: AudioDeviceID?
    private var orderedDeviceIDs: [AudioDeviceID] = []
    private var eligibleInputDeviceIDs: Set<AudioDeviceID> = []
    private var ordinaryInputDeviceIDs: Set<AudioDeviceID> = []
    private var currentDeviceID: AudioDeviceID?
    private var currentDeviceIndex = -1
    private var restartProblem: String?
    private var configurationObserver: NSObjectProtocol?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var watchdog: DispatchSourceTimer?
    private var preferredProbeEngine: AVAudioEngine?
    private var preferredProbeDeviceID: AudioDeviceID?
    private var preferredProbeGeneration: UInt64 = 0
    private var promotedProbeGeneration: UInt64?
    private var nextPreferredProbeAt = Date.distantPast
    private var active = false
    private var generation: UInt64 = 0
    private var lastFramesAt = Date()
    private var watchdogGraceUntil = Date.distantPast
    private var isSleeping = false
    private var quietPeriodNeedsFrameGrace = false
    private var lastObservedDefaultInputID: AudioDeviceID?
    private var retryAt: Date?
    private var recentErrors: [String] = []

    init(
        handler: @escaping Handler,
        onProblem: @escaping @Sendable (String?) -> Void = { _ in },
        onDeviceNotice: @escaping @Sendable (String?) -> Void = { _ in },
        onRestart: @escaping @Sendable () -> Void = {}
    ) {
        self.handler = handler
        self.onProblem = onProblem
        self.onDeviceNotice = onDeviceNotice
        self.onRestart = onRestart
    }

    var problem: String? { queue.sync { restartProblem } }

    func start(
        preferredDeviceID: AudioDeviceID?,
        preferredDeviceUID: String? = nil,
        followsSystemDefaultInput: Bool = false
    ) {
        queue.sync {
            guard !active else { return }
            active = true
            self.preferredDeviceID = preferredDeviceID
            self.followsSystemDefaultInput = followsSystemDefaultInput
            self.preferredDeviceUID = followsSystemDefaultInput
                ? nil
                : preferredDeviceUID ?? preferredDeviceID.flatMap { deviceUID($0) }
            lastObservedDefaultInputID = systemDefaultInput()
            refreshOrderedDevices()
            installDeviceListeners()
            tryNextDevice(startingAt: 0)
            startWatchdog()
        }
    }

    func stop() {
        queue.sync {
            guard active else { return }
            active = false
            watchdog?.cancel()
            watchdog = nil
            removeDeviceListeners()
            removeConfigurationObserver()
            stopPreferredProbe()
            isSleeping = false
            quietPeriodNeedsFrameGrace = false
            watchdogGraceUntil = .distantPast
            stop(engine)
            generation &+= 1
            currentDeviceID = nil
        }
    }

    private func installTapAndStart(
        on targetEngine: AVAudioEngine,
        generation tapGeneration: UInt64,
        receiveFrames: @escaping FrameReceiver
    ) throws {
        let inputNode = targetEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.inputUnavailable }
        inputNode.removeTap(onBus: 0)
        var exceptionError: NSError?
        let installed = VIInstallMeetingAudioTap(inputNode, format, { buffer, time in
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
            receiveFrames(tapGeneration, mono, buffer.format.sampleRate, time.isHostTimeValid ? time.hostTime : 0)
        }, &exceptionError)
        guard installed else { throw exceptionError ?? CaptureError.inputUnavailable }
        do {
            try targetEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }
    }

    private func receivedFrames(
        generation callbackGeneration: UInt64,
        samples: [Float],
        sampleRate: Double,
        hostTime: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, self.active, self.generation == callbackGeneration else { return }
            self.acceptFrames(samples, sampleRate: sampleRate, hostTime: hostTime)
        }
    }

    private func receivedPreferredProbeFrames(
        generation callbackGeneration: UInt64,
        deviceID: AudioDeviceID,
        samples: [Float],
        sampleRate: Double,
        hostTime: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            if self.preferredProbeGeneration == callbackGeneration,
               self.preferredProbeDeviceID == deviceID,
               let probeEngine = self.preferredProbeEngine {
                self.promotePreferredProbe(
                    probeEngine, deviceID: deviceID, generation: callbackGeneration
                )
                self.acceptFrames(samples, sampleRate: sampleRate, hostTime: hostTime)
            } else if self.promotedProbeGeneration == callbackGeneration,
                      self.currentDeviceID == deviceID {
                self.acceptFrames(samples, sampleRate: sampleRate, hostTime: hostTime)
            }
        }
    }

    private func acceptFrames(_ samples: [Float], sampleRate: Double, hostTime: UInt64) {
        lastFramesAt = Date()
        if quietPeriodNeedsFrameGrace {
            quietPeriodNeedsFrameGrace = false
            isSleeping = false
            watchdogGraceUntil = Date().addingTimeInterval(5)
        }
        if restartProblem != nil {
            restartProblem = nil
            onProblem(nil)
        }
        handler(samples, sampleRate, hostTime)
    }

    private func observeConfigurationChanges() {
        removeConfigurationObserver()
        let observedEngine = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: observedEngine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.engine === observedEngine else { return }
                self.handleEngineConfigurationChange()
            }
        }
    }

    private func handleEngineConfigurationChange() {
        guard active else { return }
        guard !engine.isRunning, let deviceID = currentDeviceID else {
            handleDeviceListChange()
            return
        }
        restartCurrentDevice(deviceID)
    }

    private func restartCurrentDevice(_ deviceID: AudioDeviceID) {
        stopPreferredProbe()
        removeConfigurationObserver()
        stop(engine)
        generation &+= 1
        currentDeviceID = nil
        currentDeviceIndex = -1
        retryAt = nil
        engine = AVAudioEngine()
        do {
            try selectInputDevice(deviceID, on: engine)
            try installTapAndStart(on: engine, generation: generation) { [weak self] callbackGeneration, samples, rate, hostTime in
                self?.receivedFrames(
                    generation: callbackGeneration, samples: samples, sampleRate: rate, hostTime: hostTime
                )
            }
            currentDeviceID = deviceID
            currentDeviceIndex = orderedDeviceIDs.firstIndex(of: deviceID) ?? -1
            lastFramesAt = Date()
            watchdogGraceUntil = Date().addingTimeInterval(5)
            quietPeriodNeedsFrameGrace = true
            observeConfigurationChanges()
            onRestart()
            onDeviceNotice(nil)
            logger.notice("Meeting microphone restarted on the same device after a format change")
            startPreferredProbeIfNeeded(force: true)
        } catch {
            recentErrors.append("\(deviceName(deviceID)): \(error.localizedDescription)")
            logger.error("Meeting microphone could not restart after a format change: \(error.localizedDescription, privacy: .public)")
            stop(engine)
            currentDeviceID = nil
            currentDeviceIndex = -1
            tryNextDevice(startingAt: 0, skippingDeviceID: deviceID)
        }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    private func handleDeviceListChange() {
        guard active else { return }
        let oldPreferredDeviceID = resolvedPreferredDeviceID
        let oldCurrentDeviceID = currentDeviceID
        let oldEligibleInputDeviceIDs = eligibleInputDeviceIDs
        let oldOrdinaryInputDeviceIDs = ordinaryInputDeviceIDs
        let defaultID = systemDefaultInput()
        let followedDefaultChanged = followsSystemDefaultInput && defaultID != lastObservedDefaultInputID
        lastObservedDefaultInputID = defaultID
        let currentDeviceStillAvailable = oldCurrentDeviceID.map { id in
            allAudioDevices().contains(id) && inputChannelCount(id) > 0
        } ?? false
        refreshOrderedDevices()
        let eligibleInputsChanged = oldEligibleInputDeviceIDs != eligibleInputDeviceIDs
        let relevantInputsChanged = oldOrdinaryInputDeviceIDs != ordinaryInputDeviceIDs
        let preferredDeviceChanged = oldPreferredDeviceID != resolvedPreferredDeviceID
        if oldCurrentDeviceID == nil {
            guard eligibleInputsChanged || preferredDeviceChanged || followedDefaultChanged else { return }
        } else {
            guard !currentDeviceStillAvailable || followedDefaultChanged else {
                if let currentDeviceID {
                    currentDeviceIndex = orderedDeviceIDs.firstIndex(of: currentDeviceID) ?? -1
                }
                if relevantInputsChanged || preferredDeviceChanged {
                    startPreferredProbeIfNeeded(force: true)
                }
                return
            }
        }
        recentErrors = []
        tryNextDevice(startingAt: 0)
    }

    private func refreshOrderedDevices() {
        let allDevices = allAudioDevices()
        // Voicer's own private call-capture device is never a microphone, even when no other input exists.
        let inputDevices = allDevices.filter { inputChannelCount($0) > 0 && !isVoicerPrivateDevice($0) }
        let defaultID = systemDefaultInput()
        let ordinaryDevices = inputDevices.filter { device in
            let name = deviceName(device).lowercased()
            let transport = transportType(device)
            return transport != kAudioDeviceTransportTypeVirtual
                && transport != kAudioDeviceTransportTypeAggregate
                && !["virtual", "blackhole", "loopback", "aggregate"].contains { name.contains($0) }
        }
        ordinaryInputDeviceIDs = Set(ordinaryDevices)
        let candidates = ordinaryDevices.isEmpty ? inputDevices : ordinaryDevices
        eligibleInputDeviceIDs = Set(candidates)
        resolvedPreferredDeviceID = preferredDeviceUID.flatMap { uid in
            inputDevices.first(where: { deviceUID($0) == uid })
        }
        var ordered: [AudioDeviceID] = []
        func append(_ device: AudioDeviceID?) {
            guard let device, !ordered.contains(device) else { return }
            ordered.append(device)
        }

        // Resolve the chosen input by UID so a reconnected device with a new numeric ID wins again.
        // In system-default mode the live default takes priority over the input used at meeting start.
        if followsSystemDefaultInput {
            if let defaultID, candidates.contains(defaultID) { append(defaultID) }
        } else if let resolvedPreferredDeviceID, candidates.contains(resolvedPreferredDeviceID) {
            append(resolvedPreferredDeviceID)
        } else if preferredDeviceUID == nil, let preferredDeviceID, candidates.contains(preferredDeviceID) {
            append(preferredDeviceID)
        }
        if !followsSystemDefaultInput, let defaultID, candidates.contains(defaultID) { append(defaultID) }
        append(candidates.first(where: isBuiltInMicrophone))
        candidates.forEach { append($0) }
        if ordered.isEmpty { inputDevices.forEach { append($0) } }
        orderedDeviceIDs = ordered
    }

    private func tryNextDevice(startingAt index: Int, skippingDeviceID: AudioDeviceID? = nil) {
        guard active else { return }
        stopPreferredProbe()
        let previousPreferredDeviceID = resolvedPreferredDeviceID
        let previousCurrentDeviceID = currentDeviceID
        refreshOrderedDevices()
        let preferredDeviceChanged = previousPreferredDeviceID != resolvedPreferredDeviceID
            && resolvedPreferredDeviceID != nil
            && resolvedPreferredDeviceID != previousCurrentDeviceID
        let defaultID = systemDefaultInput()
        let defaultDeviceChanged = followsSystemDefaultInput && defaultID != lastObservedDefaultInputID
        if defaultDeviceChanged { lastObservedDefaultInputID = defaultID }
        var firstDeviceIndex = index
        if index == 0 || preferredDeviceChanged || defaultDeviceChanged {
            firstDeviceIndex = 0
        } else if let previousCurrentDeviceID,
                  let currentIndex = orderedDeviceIDs.firstIndex(of: previousCurrentDeviceID)
        {
            firstDeviceIndex = currentIndex + 1
        }
        removeConfigurationObserver()
        stop(engine)
        generation &+= 1
        currentDeviceID = nil
        currentDeviceIndex = -1
        retryAt = nil

        guard firstDeviceIndex < orderedDeviceIDs.count else {
            reportExhaustedDevices()
            return
        }

        var nextIndex = firstDeviceIndex
        while nextIndex < orderedDeviceIDs.count {
            let deviceID = orderedDeviceIDs[nextIndex]
            if deviceID == skippingDeviceID {
                nextIndex += 1
                continue
            }
            generation &+= 1
            engine = AVAudioEngine()
            do {
                try selectInputDevice(deviceID, on: engine)
                try installTapAndStart(on: engine, generation: generation) { [weak self] callbackGeneration, samples, rate, hostTime in
                    self?.receivedFrames(
                        generation: callbackGeneration, samples: samples, sampleRate: rate, hostTime: hostTime
                    )
                }
                currentDeviceID = deviceID
                currentDeviceIndex = nextIndex
                lastFramesAt = Date()
                watchdogGraceUntil = Date().addingTimeInterval(5)
                quietPeriodNeedsFrameGrace = true
                let requestedFirst = followsSystemDefaultInput
                    ? systemDefaultInput()
                    : resolvedPreferredDeviceID ?? preferredDeviceID ?? systemDefaultInput()
                let notice = deviceID == requestedFirst ? nil : "Using \(deviceName(deviceID))"
                onRestart()
                onDeviceNotice(notice)
                observeConfigurationChanges()
                logger.notice("Meeting microphone started on \(self.deviceName(deviceID), privacy: .public)")
                startPreferredProbeIfNeeded(force: true)
                return
            } catch {
                recentErrors.append("\(deviceName(deviceID)): \(error.localizedDescription)")
                logger.error("Meeting microphone failed on \(self.deviceName(deviceID), privacy: .public): \(error.localizedDescription, privacy: .public)")
                stop(engine)
            }
            nextIndex += 1
        }

        reportExhaustedDevices()
    }

    private func reportExhaustedDevices() {
        if Date() < watchdogGraceUntil {
            retryAt = watchdogGraceUntil
            return
        }
        let message = "Microphone is not picking anything up."
        restartProblem = message
        onProblem(message)
        onDeviceNotice(nil)
        retryAt = Date().addingTimeInterval(10)
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.active else { return }
            let now = Date()
            if self.isSleeping, now >= self.watchdogGraceUntil { self.isSleeping = false }
            guard !self.isSleeping, now >= self.watchdogGraceUntil else { return }
            self.startPreferredProbeIfNeeded(force: false)
            if self.currentDeviceID != nil {
                guard now.timeIntervalSince(self.lastFramesAt) >= 4 else { return }
                if self.currentDeviceIndex + 1 < self.orderedDeviceIDs.count {
                    self.logger.error("Meeting microphone delivered no frames; trying the next input")
                    self.tryNextDevice(startingAt: self.currentDeviceIndex + 1)
                } else {
                    self.generation &+= 1
                    self.stop(self.engine)
                    self.currentDeviceID = nil
                    self.currentDeviceIndex = -1
                    self.recentErrors = []
                    self.reportExhaustedDevices()
                }
            } else if let retryAt = self.retryAt, now >= retryAt {
                self.refreshOrderedDevices()
                self.recentErrors = []
                self.tryNextDevice(startingAt: 0)
            }
        }
        watchdog = timer
        timer.resume()
    }

    private func installDeviceListeners() {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.active else { return }
            self.queue.async { [weak self] in self?.handleDeviceListChange() }
        }
        deviceListener = listener
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, queue, listener)
        if status != noErr { deviceListener = nil }

        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.active else { return }
            self.queue.async { [weak self] in self?.handleDefaultInputChange() }
        }
        defaultInputListener = defaultListener
        let defaultStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddress, queue, defaultListener)
        if defaultStatus != noErr { defaultInputListener = nil }

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.active else { return }
                self.isSleeping = true
                let sleepStartedAt = Date()
                self.lastFramesAt = sleepStartedAt
                self.quietPeriodNeedsFrameGrace = true
                self.watchdogGraceUntil = sleepStartedAt.addingTimeInterval(30)
            }
        }

        // Waking does not always post an AVAudioEngine configuration change, but the old engine may have died.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self, self.active else { return }
            self.queue.async { [weak self] in
                guard let self, self.active else { return }
                self.isSleeping = false
                self.quietPeriodNeedsFrameGrace = true
                self.lastFramesAt = Date()
                self.watchdogGraceUntil = Date().addingTimeInterval(5)
                self.lastObservedDefaultInputID = self.systemDefaultInput()
                self.refreshOrderedDevices()
                self.recentErrors = []
                self.tryNextDevice(startingAt: 0)
            }
        }
    }

    private func handleDefaultInputChange() {
        guard active else { return }
        let defaultID = systemDefaultInput()
        guard defaultID != lastObservedDefaultInputID else { return }
        lastObservedDefaultInputID = defaultID
        guard followsSystemDefaultInput else { return }
        refreshOrderedDevices()
        recentErrors = []
        tryNextDevice(startingAt: 0)
    }

    private var retryPreferredDeviceID: AudioDeviceID? {
        guard !followsSystemDefaultInput else { return nil }
        if let resolvedPreferredDeviceID { return resolvedPreferredDeviceID }
        guard preferredDeviceUID == nil,
              let preferredDeviceID,
              eligibleInputDeviceIDs.contains(preferredDeviceID) else { return nil }
        return preferredDeviceID
    }

    private func startPreferredProbeIfNeeded(force: Bool) {
        guard active else {
            stopPreferredProbe()
            return
        }
        guard let preferredID = retryPreferredDeviceID,
              eligibleInputDeviceIDs.contains(preferredID) else {
            stopPreferredProbe()
            return
        }
        if preferredID == currentDeviceID {
            if preferredProbeEngine != nil { stopPreferredProbe() }
            return
        }
        if preferredProbeDeviceID == preferredID, preferredProbeEngine?.isRunning == true {
            guard force || Date() >= nextPreferredProbeAt else { return }
        }
        guard force || Date() >= nextPreferredProbeAt else { return }

        stopPreferredProbe()
        preferredProbeGeneration &+= 1
        let probeGeneration = preferredProbeGeneration
        let probeEngine = AVAudioEngine()
        preferredProbeEngine = probeEngine
        preferredProbeDeviceID = preferredID
        nextPreferredProbeAt = Date().addingTimeInterval(30)
        do {
            try selectInputDevice(preferredID, on: probeEngine)
            try installTapAndStart(on: probeEngine, generation: probeGeneration) { [weak self] callbackGeneration, samples, rate, hostTime in
                self?.receivedPreferredProbeFrames(
                    generation: callbackGeneration, deviceID: preferredID,
                    samples: samples, sampleRate: rate, hostTime: hostTime
                )
            }
            logger.notice("Meeting microphone is retrying the chosen input while fallback audio continues")
        } catch {
            logger.error("Meeting microphone could not retry the chosen input: \(error.localizedDescription, privacy: .public)")
            stop(probeEngine)
            preferredProbeEngine = nil
            preferredProbeDeviceID = nil
            preferredProbeGeneration &+= 1
        }
    }

    private func stopPreferredProbe() {
        if let preferredProbeEngine { stop(preferredProbeEngine) }
        preferredProbeEngine = nil
        preferredProbeDeviceID = nil
        preferredProbeGeneration &+= 1
        promotedProbeGeneration = nil
    }

    private func promotePreferredProbe(_ probeEngine: AVAudioEngine, deviceID: AudioDeviceID, generation probeGeneration: UInt64) {
        removeConfigurationObserver()
        generation &+= 1
        stop(engine)
        engine = probeEngine
        preferredProbeEngine = nil
        preferredProbeDeviceID = nil
        promotedProbeGeneration = probeGeneration
        currentDeviceID = deviceID
        currentDeviceIndex = orderedDeviceIDs.firstIndex(of: deviceID) ?? -1
        lastFramesAt = Date()
        watchdogGraceUntil = Date().addingTimeInterval(5)
        quietPeriodNeedsFrameGrace = true
        observeConfigurationChanges()
        onRestart()
        onDeviceNotice(nil)
        logger.notice("Meeting microphone switched back to the chosen input after receiving audio")
    }

    private func removeDeviceListeners() {
        if let deviceListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, deviceListener)
            self.deviceListener = nil
        }
        if let defaultInputListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, defaultInputListener)
            self.defaultInputListener = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
    }

    private func selectInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
        guard let audioUnit = engine.inputNode.audioUnit else { throw CaptureError.inputUnavailable }
        var device = deviceID
        let status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &device,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw CaptureError.coreAudio(status) }
    }

    private func stop(_ engine: AVAudioEngine) {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    private func allAudioDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else {
            return []
        }
        return devices
    }

    private func inputChannelCount(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let buffers = storage.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffers) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(buffers).reduce(UInt32(0)) { $0 + $1.mNumberChannels }
    }

    private func systemDefaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard withUnsafeMutablePointer(to: &name, {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }) == noErr,
              let name else { return "Microphone" }
        return name.takeRetainedValue() as String
    }

    private func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard withUnsafeMutablePointer(to: &uid, {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }) == noErr,
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    /// The combined device SystemAudioTap builds for call capture (its UID starts with this prefix).
    private func isVoicerPrivateDevice(_ deviceID: AudioDeviceID) -> Bool {
        deviceUID(deviceID)?.hasPrefix("com.ashadmohammed.voicer.meeting-tap.") == true
    }

    private func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private func isBuiltInMicrophone(_ deviceID: AudioDeviceID) -> Bool {
        transportType(deviceID) == kAudioDeviceTransportTypeBuiltIn
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
