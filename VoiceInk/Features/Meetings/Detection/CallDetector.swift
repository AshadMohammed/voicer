import Combine
import Foundation
import os
import SwiftUI

/// Orchestrates call detection: watches the microphone, runs the policy engine, and shows prompts.
@MainActor
final class CallDetector {
    static let shared = CallDetector()
    static let settingKey = "askToRecordCalls"   // Bool, default true when unset

    private let monitor = MicActivityMonitor()
    private var policy = CallDetectionPolicy()
    private let logger = Logger(subsystem: "com.ashadmohammed.voicer", category: "CallDetection")

    private var tickTimer: Timer?
    private var recordingSubscription: AnyCancellable?
    private var settingsObserver: NSObjectProtocol?
    private var lastKnownBusy = false
    private var performing = false
    private var deferredActions: [CallDetectionPolicy.Action] = []

    /// What to call a meeting recorded right now: the call app, the meeting site in a browser, or the browser.
    /// Nil when nothing recognisable is using the microphone.
    private(set) var currentCallName: String?
    private var activeSources = Set<CallSource>()
    /// Meeting sites already read from each browser's tab, by browser ID.
    private var browserSiteNames: [String: String] = [:]

    /// Bundle IDs we've already logged, to avoid repeating the log every time.
    private var loggedBundleIDs = Set<String>()

    private var isEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: Self.settingKey) == nil ? true : defaults.bool(forKey: Self.settingKey)
    }

    private init() {}

    /// Called once at launch; idempotent.
    func start() {
        guard settingsObserver == nil else { return }

        // Watch settings changes.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.settingChanged()
            }
        }

        if isEnabled {
            enableDetection()
        }
    }

    // MARK: - Enable / disable

    private func enableDetection() {
        monitor.onChange = { [weak self] processes in
            MainActor.assumeIsolated {
                self?.micProcessesChanged(processes)
            }
        }
        monitor.start()

        // Subscribe to recording state.
        recordingSubscription = MeetingsCoordinator.shared.$recordingState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                MainActor.assumeIsolated {
                    self?.recordingStateChanged(state)
                }
            }

        startTick()
    }

    private func disableDetection() {
        monitor.onChange = nil
        monitor.stop()
        stopTick()
        recordingSubscription = nil
        loggedBundleIDs = []

        let actions = policy.reset()
        perform(actions)
    }

    private func settingChanged() {
        if isEnabled {
            // Only enable if not already ticking (i.e. was disabled).
            if tickTimer == nil {
                enableDetection()
            }
        } else {
            if tickTimer != nil {
                disableDetection()
            }
        }
    }

    // MARK: - Tick timer

    private func startTick() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let actions = self.policy.tick(now: Date())
                self.perform(actions)
            }
        }
    }

    private func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - Monitor callback

    private func micProcessesChanged(_ processes: Set<MicProcess>) {
        var sources = Set<CallSource>()
        for process in processes {
            let bid = process.bundleID
            if !loggedBundleIDs.contains(bid) {
                loggedBundleIDs.insert(bid)
                if let source = CallAppCatalog.source(forBundleID: bid) {
                    logger.info("Mic active: \(bid, privacy: .public) → \(source.name, privacy: .public)")
                } else {
                    logger.info("Mic active: \(bid, privacy: .public) → no match")
                }
            }
            if let source = CallAppCatalog.source(forBundleID: bid) {
                sources.insert(source)
            }
        }

        if lastKnownBusy {
            // Kept in the log at notice level so a missed call end can be traced afterwards.
            let ids = processes.map(\.bundleID).sorted().joined(separator: ", ")
            logger.notice("While recording, mic in use by: \(ids.isEmpty ? "nobody" : ids, privacy: .public)")
        }
        activeSources = sources
        if sources.isEmpty { browserSiteNames = [:] }
        updateCurrentCallName()

        let actions = policy.micSourcesChanged(sources, now: Date())
        perform(actions)
    }

    private func updateCurrentCallName() {
        if let app = activeSources.filter({ $0.kind == .app }).sorted(by: { $0.name < $1.name }).first {
            currentCallName = app.name
        } else if let browser = activeSources.sorted(by: { $0.name < $1.name }).first {
            currentCallName = browserSiteNames[browser.id] ?? browser.name
        } else {
            currentCallName = nil
        }
    }

    // MARK: - Recording state

    private func recordingStateChanged(_ state: MeetingsCoordinator.RecordingState) {
        let busy = state != .idle
        guard busy != lastKnownBusy else { return }
        lastKnownBusy = busy
        let actions = policy.recordingChanged(isBusy: busy, now: Date())
        perform(actions)
    }

    // MARK: - Perform actions (re-entrancy safe)

    private func perform(_ actions: [CallDetectionPolicy.Action]) {
        if performing {
            deferredActions.append(contentsOf: actions)
            return
        }
        performing = true
        var queue = actions
        while !queue.isEmpty {
            let action = queue.removeFirst()
            execute(action)
            // Drain any actions that were added re-entrantly.
            if !deferredActions.isEmpty {
                queue.append(contentsOf: deferredActions)
                deferredActions = []
            }
        }
        performing = false
    }

    private func execute(_ action: CallDetectionPolicy.Action) {
        switch action {
        case .showPrompt(let prompt):
            showPrompt(prompt)
        case .hidePrompt:
            logger.info("Hiding prompt")
            CallPromptPanelController.shared.hide()
            MeetingIndicatorController.shared.hideCallEnded()
        case .checkBrowserTab(let source):
            checkBrowserTab(source)
        case .startRecording:
            logger.info("Starting recording from call detection")
            MeetingsCoordinator.shared.startRecording()
        case .stopRecording:
            logger.notice("Stopping recording from call detection")
            MeetingsCoordinator.shared.stopRecording()
        }
    }

    // MARK: - Prompt

    private func showPrompt(_ prompt: CallDetectionPolicy.Prompt) {
        switch prompt {
        case .start(_, let displayName):
            let message = String(
                format: String(localized: "%@ is on a call. Record it?"),
                displayName
            )
            logger.info("Showing start prompt: \(message, privacy: .public)")
            CallPromptPanelController.shared.show(
                message: message,
                primaryTitle: String(localized: "Record"),
                secondaryTitle: String(localized: "Not now"),
                belowIndicator: false,
                onPrimary: { [weak self] in
                    guard let self else { return }
                    let actions = self.policy.userTappedRecord(now: Date())
                    self.perform(actions)
                    self.logger.info("User tapped Record")
                },
                onSecondary: { [weak self] in
                    guard let self else { return }
                    let actions = self.policy.userTappedNotNow(now: Date())
                    self.perform(actions)
                    self.logger.info("User tapped Not now")
                }
            )
        case .end:
            // The meeting pill shows this one itself, with a countdown to the automatic stop.
            logger.notice("Call ended: showing the stop countdown")
            MeetingIndicatorController.shared.showCallEnded(
                deadline: Date().addingTimeInterval(policy.endCountdown),
                onKeep: { [weak self] in
                    guard let self else { return }
                    let actions = self.policy.userTappedKeepRecording(now: Date())
                    self.perform(actions)
                    self.logger.notice("User tapped Keep recording")
                }
            )
        }
    }

    // MARK: - Browser tab check

    private func checkBrowserTab(_ source: CallSource) {
        // Find the BrowserType whose bundleIdentifier matches source.id.
        guard let browserType = BrowserType.allCases.first(where: { $0.bundleIdentifier == source.id }) else {
            // No matching browser type; treat as nil site.
            let actions = policy.browserTabChecked(source, meetingSite: nil, now: Date())
            perform(actions)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            var site: String?
            do {
                let url = try await BrowserURLService.shared.getCurrentURL(from: browserType)
                site = CallAppCatalog.meetingSite(forURL: url)
            } catch {
                // A thrown error = nil site.
                site = nil
            }
            if let site { self.browserSiteNames[source.id] = site }
            self.updateCurrentCallName()
            let actions = self.policy.browserTabChecked(source, meetingSite: site, now: Date())
            self.perform(actions)
        }
    }
}
