import Foundation

/// Pure decision engine for call detection. A value type; every entry point returns the actions for the caller
/// to carry out. No timers, UI, Core Audio or app types – just logic that can be tested with synthetic events.
struct CallDetectionPolicy {

    enum Prompt: Equatable {
        case start(CallSource, displayName: String)   // "<displayName> is on a call. Record it?"
        case end                                       // "Call ended, saving in 10s" with Keep recording
    }

    enum Action: Equatable {
        case showPrompt(Prompt)
        case hidePrompt
        case checkBrowserTab(CallSource)   // read this browser's current tab, then call browserTabChecked
        case startRecording
        case stopRecording
    }

    var startDelay: TimeInterval = 2
    /// How long the call's sources must be gone from the mic before the call counts as ended.
    var endDelay: TimeInterval = 5
    /// How long the "call ended" notice stays up before the recording is stopped and saved.
    var endCountdown: TimeInterval = 10
    var promptTimeout: TimeInterval = 60
    var browserCheckInterval: TimeInterval = 3
    var browserCheckWindow: TimeInterval = 15

    private(set) var prompt: Prompt?

    // MARK: - Internal state

    /// Currently active call sources, with the time each was first seen.
    private var activeSources: [CallSource: Date] = [:]

    /// Sources the user said "Not now" to (or that timed out). Snoozed until they leave the mic.
    private var snoozed = Set<CallSource>()

    /// While busy: the call sources that belong to the current recording.
    private var recordingCallSources = Set<CallSource>()
    private var isBusy = false

    /// When all recording call sources left the mic (for the end-prompt delay).
    private var allSourcesLeftAt: Date?

    /// Timestamp the current start prompt was shown.
    private var startPromptShownAt: Date?
    /// The source the start prompt is for.
    private var startPromptSource: CallSource?
    /// Timestamp the current end prompt was shown.
    private var endPromptShownAt: Date?

    // Browser tab checking
    private var browserFirstCheckAt: [CallSource: Date] = [:]
    private var browserLastCheckAt: [CallSource: Date] = [:]
    private var browserCheckOutstanding = Set<CallSource>()
    private var confirmedSites: [CallSource: String] = [:]

    init() {}

    // MARK: - Entry points

    mutating func micSourcesChanged(_ active: Set<CallSource>, now: Date) -> [Action] {
        var actions: [Action] = []

        // Detect sources that left.
        let departed = Set(activeSources.keys).subtracting(active)
        for source in departed {
            activeSources.removeValue(forKey: source)
            snoozed.remove(source)
            browserFirstCheckAt.removeValue(forKey: source)
            browserLastCheckAt.removeValue(forKey: source)
            browserCheckOutstanding.remove(source)
            confirmedSites.removeValue(forKey: source)

            // If the shown prompt is .start for this source → hidePrompt.
            if case .start(let s, _) = prompt, s == source {
                actions.append(.hidePrompt)
                prompt = nil
                startPromptShownAt = nil
                startPromptSource = nil
            }
        }

        // Detect newly arrived sources.
        for source in active where activeSources[source] == nil {
            activeSources[source] = now
        }

        // Rule 5 addendum: while busy, any newly active source joins recording call sources.
        if isBusy {
            for source in active where !recordingCallSources.contains(source) {
                if departed.isEmpty || !departed.contains(source) {
                    // Only truly new arrivals (ones not already tracked as recording sources).
                }
                recordingCallSources.insert(source)
            }
        }

        // Rule 6: while busy with call sources, check the "ended" clock.
        if isBusy && !recordingCallSources.isEmpty {
            let anyRecordingSourceActive = !recordingCallSources.isDisjoint(with: active)
            if anyRecordingSourceActive {
                allSourcesLeftAt = nil
                // If end prompt is showing, hide it.
                if case .end = prompt {
                    actions.append(.hidePrompt)
                    prompt = nil
                    endPromptShownAt = nil
                }
            } else if allSourcesLeftAt == nil {
                allSourcesLeftAt = now
            }
        }

        actions += evaluateStartPrompt(now: now)
        actions += evaluateEndPrompt(now: now)
        return actions
    }

    mutating func recordingChanged(isBusy busy: Bool, now: Date) -> [Action] {
        var actions: [Action] = []

        if busy && !isBusy {
            // Rule 5: became busy.
            isBusy = true
            if case .start = prompt {
                actions.append(.hidePrompt)
                prompt = nil
                startPromptShownAt = nil
                startPromptSource = nil
            }
            // Every active source joins the recording's call sources.
            for source in activeSources.keys {
                recordingCallSources.insert(source)
            }
            allSourcesLeftAt = nil
        } else if !busy && isBusy {
            // Rule 8: became idle.
            isBusy = false
            if case .end = prompt {
                actions.append(.hidePrompt)
                prompt = nil
                endPromptShownAt = nil
            }
            // Snooze every currently active source.
            for source in activeSources.keys {
                snoozed.insert(source)
            }
            recordingCallSources = []
            allSourcesLeftAt = nil
        }

        actions += evaluateStartPrompt(now: now)
        return actions
    }

    mutating func browserTabChecked(
        _ source: CallSource,
        meetingSite: String?,
        fallbackName: String? = nil,
        now: Date
    ) -> [Action] {
        var actions: [Action] = []
        browserCheckOutstanding.remove(source)

        if let site = meetingSite ?? fallbackName {
            confirmedSites[source] = site
            // If no prompt is shown and not busy and not snoozed, show the prompt.
            if prompt == nil && !isBusy && !snoozed.contains(source) && activeSources[source] != nil {
                let displayName = site
                prompt = .start(source, displayName: displayName)
                startPromptShownAt = now
                startPromptSource = source
                actions.append(.showPrompt(prompt!))
            }
        }

        actions += evaluateStartPrompt(now: now)
        return actions
    }

    mutating func tick(now: Date) -> [Action] {
        var actions: [Action] = []

        // Check start-prompt timeout (rule 4).
        if case .start = prompt, let shownAt = startPromptShownAt, now.timeIntervalSince(shownAt) >= promptTimeout {
            actions += handleNotNow()
        }

        // Nobody answered the end notice: stop and save.
        if case .end = prompt, let shownAt = endPromptShownAt, now.timeIntervalSince(shownAt) >= endCountdown {
            actions += handleEndCountdownElapsed()
        }

        actions += evaluateStartPrompt(now: now)
        actions += evaluateEndPrompt(now: now)
        return actions
    }

    mutating func userTappedRecord(now: Date) -> [Action] {
        var actions: [Action] = []
        guard case .start(let source, _) = prompt else { return actions }

        // Rule 3: Record.
        actions.append(.hidePrompt)
        prompt = nil
        startPromptShownAt = nil
        startPromptSource = nil

        // That source joins recording call sources; mark busy immediately.
        recordingCallSources.insert(source)
        isBusy = true
        // All other active sources also join.
        for s in activeSources.keys {
            recordingCallSources.insert(s)
        }
        allSourcesLeftAt = nil

        actions.append(.startRecording)
        return actions
    }

    mutating func userTappedNotNow(now: Date) -> [Action] {
        return handleNotNow()
    }

    mutating func userTappedStopAndSave(now: Date) -> [Action] {
        var actions: [Action] = []
        guard case .end = prompt else { return actions }
        actions.append(.hidePrompt)
        prompt = nil
        endPromptShownAt = nil
        actions.append(.stopRecording)
        return actions
    }

    mutating func userTappedKeepRecording(now: Date) -> [Action] {
        return handleKeepRecording()
    }

    mutating func reset() -> [Action] {
        var actions: [Action] = []
        if prompt != nil {
            actions.append(.hidePrompt)
        }
        activeSources = [:]
        snoozed = []
        recordingCallSources = []
        isBusy = false
        allSourcesLeftAt = nil
        startPromptShownAt = nil
        startPromptSource = nil
        endPromptShownAt = nil
        browserFirstCheckAt = [:]
        browserLastCheckAt = [:]
        browserCheckOutstanding = []
        confirmedSites = [:]
        prompt = nil
        return actions
    }

    // MARK: - Private helpers

    /// The end notice ran out without "Keep recording": hide it and stop the recording.
    private mutating func handleEndCountdownElapsed() -> [Action] {
        guard case .end = prompt else { return [] }
        prompt = nil
        endPromptShownAt = nil
        return [.hidePrompt, .stopRecording]
    }

    /// Handle "Keep recording": keep recording, hide prompt, reset call sources.
    private mutating func handleKeepRecording() -> [Action] {
        var actions: [Action] = []
        guard case .end = prompt else { return actions }
        actions.append(.hidePrompt)
        prompt = nil
        endPromptShownAt = nil
        // The call sources become just the currently active ones (normally none).
        recordingCallSources = Set(activeSources.keys)
        allSourcesLeftAt = nil
        return actions
    }

    /// Handle "Not now" or prompt timeout: snooze the source, hide the prompt.
    private mutating func handleNotNow() -> [Action] {
        var actions: [Action] = []
        guard case .start(let source, _) = prompt else { return actions }
        actions.append(.hidePrompt)
        prompt = nil
        startPromptShownAt = nil
        startPromptSource = nil
        snoozed.insert(source)
        return actions
    }

    /// Evaluate whether a start prompt should be shown (rule 2). Returns actions for browser checks or prompt display.
    private mutating func evaluateStartPrompt(now: Date) -> [Action] {
        // Don't show a start prompt while busy or while any prompt is already shown.
        guard !isBusy, prompt == nil else { return [] }

        var actions: [Action] = []

        // Find the first eligible source: active for ≥ startDelay, not snoozed.
        // Deterministic: earliest firstSeen, then by id.
        let eligible = activeSources
            .filter { !snoozed.contains($0.key) && now.timeIntervalSince($0.value) >= startDelay }
            .sorted { a, b in
                if a.value != b.value { return a.value < b.value }
                return a.key.id < b.key.id
            }

        guard let (source, _) = eligible.first else { return [] }

        if source.kind == .app {
            prompt = .start(source, displayName: source.name)
            startPromptShownAt = now
            startPromptSource = source
            actions.append(.showPrompt(prompt!))
        } else {
            // Browser: needs a confirmed meeting site first.
            if let site = confirmedSites[source] {
                prompt = .start(source, displayName: site)
                startPromptShownAt = now
                startPromptSource = source
                actions.append(.showPrompt(prompt!))
            } else {
                // Check if we should emit a browser tab check.
                actions += emitBrowserCheckIfNeeded(source, now: now)
            }
        }

        return actions
    }

    /// Emit a checkBrowserTab action if appropriate timing allows.
    private mutating func emitBrowserCheckIfNeeded(_ source: CallSource, now: Date) -> [Action] {
        // Don't re-emit while one is outstanding.
        guard !browserCheckOutstanding.contains(source) else { return [] }

        // If we've never checked, start now.
        guard let firstCheck = browserFirstCheckAt[source] else {
            browserFirstCheckAt[source] = now
            browserLastCheckAt[source] = now
            browserCheckOutstanding.insert(source)
            return [.checkBrowserTab(source)]
        }

        // Past the window? Snooze it.
        if now.timeIntervalSince(firstCheck) >= browserCheckWindow {
            snoozed.insert(source)
            return []
        }

        // Respect the check interval.
        if let lastCheck = browserLastCheckAt[source], now.timeIntervalSince(lastCheck) >= browserCheckInterval {
            browserLastCheckAt[source] = now
            browserCheckOutstanding.insert(source)
            return [.checkBrowserTab(source)]
        }

        return []
    }

    /// Evaluate whether the end prompt should be shown (rule 6).
    private mutating func evaluateEndPrompt(now: Date) -> [Action] {
        guard isBusy, !recordingCallSources.isEmpty else { return [] }
        // Already showing end prompt or start prompt? Don't add another.
        guard prompt == nil else { return [] }

        guard let leftAt = allSourcesLeftAt, now.timeIntervalSince(leftAt) >= endDelay else { return [] }

        prompt = .end
        endPromptShownAt = now
        return [.showPrompt(.end)]
    }
}
