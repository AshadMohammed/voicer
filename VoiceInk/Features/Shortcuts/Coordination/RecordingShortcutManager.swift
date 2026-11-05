import AppKit
import Foundation
import os

@MainActor
class RecordingShortcutManager: ObservableObject {
    @Published private(set) var shortcutMenuRevision = 0
    @Published var primaryRecordingShortcut: ShortcutSelection {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcut.rawValue, forKey: "primaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var secondaryRecordingShortcut: ShortcutSelection {
        didSet {
            if secondaryRecordingShortcut == .none {
                ShortcutStore.setShortcut(nil, for: .secondaryRecording)
            }
            UserDefaults.standard.set(secondaryRecordingShortcut.rawValue, forKey: "secondaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var primaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcutMode.rawValue, forKey: "primaryRecordingShortcutMode")
            primaryRecordingShortcutModeSource.primaryMode = primaryRecordingShortcutMode
            shortcutModeHandler.resetShortcutState(for: .primaryRecording)
            modeShortcutManager.recordingModeDidChange()
            updateStandaloneModifierActions()
        }
    }
    @Published var secondaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(secondaryRecordingShortcutMode.rawValue, forKey: "secondaryRecordingShortcutMode")
            shortcutModeHandler.resetShortcutState(for: .secondaryRecording)
            updateStandaloneModifierActions()
        }
    }
    private var engine: VoiceInkEngine
    private var recorderUIManager: RecorderUIManager
    private var recorderPanelShortcutManager: RecorderPanelShortcutManager
    private let modeShortcutManager: ModeShortcutManager
    private let shortcutMonitor = ShortcutMonitor()
    private var shortcutChangeObserver: NSObjectProtocol?
    private let shortcutModeHandler: RecordingShortcutModeHandler
    private let primaryRecordingShortcutModeSource: RecordingShortcutModeSource

    enum Mode: String, CaseIterable {
        case toggle = "toggle"
        case pushToTalk = "pushToTalk"
        case hybrid = "hybrid"
        case doubleTap = "doubleTap"
        // Hold to talk; double tap to record hands-free until the next press.
        case holdOrDoubleTap = "holdOrDoubleTap"

        var displayName: String {
            switch self {
            case .toggle: return String(localized: "Toggle")
            case .pushToTalk: return String(localized: "Push to Talk")
            case .hybrid: return String(localized: "Hybrid")
            case .doubleTap: return String(localized: "Double Tap")
            case .holdOrDoubleTap: return String(localized: "Hold or Double Tap")
            }
        }
    }

    enum ShortcutSelection: String, CaseIterable {
        case none = "none"
        case custom = "custom"

        var displayName: String {
            switch self {
            case .none: return String(localized: "None")
            case .custom: return String(localized: "Custom")
            }
        }
    }

    private static func canHandleShortcutAction(for recordingState: RecordingState) -> Bool {
        recordingState != .transcribing && recordingState != .enhancing && recordingState != .busy
    }

    init(engine: VoiceInkEngine, recorderUIManager: RecorderUIManager) {
        ShortcutMigration.migrateLegacyShortcutsIfNeeded()
        self.primaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .primaryRecording,
            allowsNone: false
        )
        self.secondaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .secondaryRecording,
            allowsNone: true
        )

        let primaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .primaryRecording
        )
        self.primaryRecordingShortcutMode = primaryRecordingShortcutMode
        self.secondaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .secondaryRecording
        )

        let shortcutModeHandler = RecordingShortcutModeHandler(
            canHandleShortcutAction: {
                Self.canHandleShortcutAction(for: engine.recordingState)
            },
            isRecorderVisible: {
                recorderUIManager.isRecorderPanelVisible
            },
            recordingState: {
                engine.recordingState
            },
            toggleRecorderPanel: { modeId in
                await recorderUIManager.toggleRecorderPanel(modeId: modeId)
            },
            cancelRecording: {
                await recorderUIManager.cancelRecording()
            }
        )

        let primaryRecordingShortcutModeSource = RecordingShortcutModeSource(
            primaryMode: primaryRecordingShortcutMode
        )

        self.engine = engine
        self.recorderUIManager = recorderUIManager
        self.recorderPanelShortcutManager = RecorderPanelShortcutManager(recorderUIManager: recorderUIManager)
        self.shortcutModeHandler = shortcutModeHandler
        self.primaryRecordingShortcutModeSource = primaryRecordingShortcutModeSource
        self.modeShortcutManager = ModeShortcutManager(
            modeProvider: {
                primaryRecordingShortcutModeSource.primaryMode
            },
            shortcutModeHandler: shortcutModeHandler
        )

        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshShortcutMonitoring()
            }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.refreshShortcutMonitoring()
        }
    }

    private func refreshShortcutMonitoring() {
        shortcutMenuRevision &+= 1
        removeAllMonitoring()

        refreshShortcutMonitor()
    }

    private func refreshShortcutMonitor() {
        let primaryShortcut = primaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .primaryRecording) : nil
        let secondaryShortcut =
            secondaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .secondaryRecording) : nil
        var shortcuts = ShortcutStore.shortcuts(for: ShortcutAction.globalUtilityActions)
        var interruptibleRecordingActions = Set<ShortcutAction>()

        if let primaryShortcut {
            shortcuts[.primaryRecording] = primaryShortcut
            interruptibleRecordingActions.insert(.primaryRecording)
        }

        if let secondaryShortcut {
            shortcuts[.secondaryRecording] = secondaryShortcut
            interruptibleRecordingActions.insert(.secondaryRecording)
        }

        shortcutMonitor.start(
            shortcuts: shortcuts,
            interruptibleActions: interruptibleRecordingActions,
            standaloneModifierActions: standaloneModifierActions,
            onShortcutDown: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }
                    guard let mode = self.recordingMode(for: action) else { return }
                    await self.shortcutModeHandler.handleShortcutDown(
                        action: action,
                        eventTime: eventTime,
                        mode: mode
                    )
                }
            },
            onShortcutUp: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }
                    if let mode = self.recordingMode(for: action) {
                        await self.shortcutModeHandler.handleShortcutUp(
                            action: action,
                            eventTime: eventTime,
                            mode: mode
                        )
                    } else {
                        await self.handleGlobalShortcut(action)
                    }
                }
            },
            onShortcutInterrupted: { [weak self] action, _ in
                Task { @MainActor in
                    guard let self, self.recordingMode(for: action) != nil else { return }
                    await self.shortcutModeHandler.handleInterruption(action: action)
                }
            },
            onStandaloneModifierChord: { [weak self] action in
                MainActor.assumeIsolated {
                    self?.shortcutModeHandler.clearPendingDoubleTap(for: action)
                }
            }
        )
    }

    private var standaloneModifierActions: Set<ShortcutAction> {
        var actions = Set<ShortcutAction>()
        if primaryRecordingShortcutMode == .toggle || primaryRecordingShortcutMode == .doubleTap {
            actions.insert(.primaryRecording)
        }
        if secondaryRecordingShortcutMode == .toggle || secondaryRecordingShortcutMode == .doubleTap {
            actions.insert(.secondaryRecording)
        }
        return actions
    }

    private func updateStandaloneModifierActions() {
        shortcutMonitor.updateStandaloneModifierActions(standaloneModifierActions)
    }

    private func recordingMode(for action: ShortcutAction) -> Mode? {
        switch action {
        case .primaryRecording:
            return primaryRecordingShortcutMode
        case .secondaryRecording:
            return secondaryRecordingShortcutMode
        default:
            return nil
        }
    }

    private func handleGlobalShortcut(_ action: ShortcutAction) async {
        switch action {
        case .pasteLastTranscription:
            LastTranscriptionService.pasteLastTranscription(from: engine.modelContext)
        case .pasteLastEnhancement:
            LastTranscriptionService.pasteLastEnhancement(from: engine.modelContext)
        case .retryLastTranscription:
            LastTranscriptionService.retryLastTranscription(
                from: engine.modelContext,
                transcriptionModelManager: engine.transcriptionModelManager,
                serviceRegistry: engine.serviceRegistry,
                enhancementService: engine.enhancementService
            )
        case .openQuickHistory:
            QuickHistoryController.shared.show(modelContext: engine.modelContext, engine: engine)
        case .quickAddToDictionary:
            DictionaryQuickAddManager.shared.toggle(modelContainer: engine.modelContext.container)
        case .toggleMeetingRecording:
            MeetingsCoordinator.shared.toggleRecording()
        default:
            break
        }
    }

    private func removeAllMonitoring() {
        shortcutMonitor.stop()

        shortcutModeHandler.reset()
    }

    var isShortcutConfigured: Bool {
        let isPrimaryShortcutConfigured =
            primaryRecordingShortcut != .none && ShortcutStore.shortcut(for: .primaryRecording) != nil
        let isSecondaryShortcutConfigured =
            secondaryRecordingShortcut == .none || ShortcutStore.shortcut(for: .secondaryRecording) != nil
        return isPrimaryShortcutConfigured && isSecondaryShortcutConfigured
    }

    func updateShortcutStatus() {
        // Called when a shortcut changes
        refreshShortcutMonitoring()
    }

    deinit {
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }

        MainActor.assumeIsolated {
            removeAllMonitoring()
        }
    }
}

@MainActor
private final class RecordingShortcutModeSource {
    var primaryMode: RecordingShortcutManager.Mode

    init(primaryMode: RecordingShortcutManager.Mode) {
        self.primaryMode = primaryMode
    }
}

/// Tells the recorder pill when a recording is locked on hands-free, so it can glow.
@MainActor
final class HandsFreeLockIndicator: ObservableObject {
    static let shared = HandsFreeLockIndicator()
    @Published var isLocked = false
}

@MainActor
final class RecordingShortcutModeHandler {
    private let canHandleShortcutAction: @MainActor () -> Bool
    private let isRecorderVisible: @MainActor () -> Bool
    private let recordingState: @MainActor () -> RecordingState
    private let toggleRecorderPanel: @MainActor (UUID?) async -> Void
    private let cancelRecording: @MainActor () async -> Void

    private var shortcutPressStartTime: TimeInterval?
    private var isHandsFreeRecording = false {
        didSet { HandsFreeLockIndicator.shared.isLocked = isHandsFreeRecording }
    }
    private var isShortcutPressed = false
    private var activeRecordingShortcutAction: ShortcutAction?
    private var interruptedRecordingActions = Set<ShortcutAction>()
    private var activeShortcutCanCancelAccidentalStart = false
    private var activeShortcutIsDoubleTap = false
    private var lastShortcutPressTime: Date?
    private var pendingDoubleTapReleaseTimes: [ShortcutAction: TimeInterval] = [:]
    // Hold-or-double-tap: the action whose first quick tap is waiting for a second tap.
    private var pendingFirstTapAction: ShortcutAction?
    private var pendingFirstTapTimeout: Task<Void, Never>?
    private var ignoresNextShortcutUp = false

    private let logger = Logger(subsystem: "com.ashadmohammed.voicer", category: "RecordingShortcut")

    private let shortcutPressCooldown: TimeInterval = 0.5
    private let hybridPressThreshold: TimeInterval = 0.5
    private let doubleTapThreshold: TimeInterval = 0.7
    private let holdPressThreshold: TimeInterval = 0.3
    private let secondTapWindow: TimeInterval = 0.5

    init(
        canHandleShortcutAction: @escaping @MainActor () -> Bool,
        isRecorderVisible: @escaping @MainActor () -> Bool,
        recordingState: @escaping @MainActor () -> RecordingState,
        toggleRecorderPanel: @escaping @MainActor (UUID?) async -> Void,
        cancelRecording: @escaping @MainActor () async -> Void
    ) {
        self.canHandleShortcutAction = canHandleShortcutAction
        self.isRecorderVisible = isRecorderVisible
        self.recordingState = recordingState
        self.toggleRecorderPanel = toggleRecorderPanel
        self.cancelRecording = cancelRecording
    }

    func reset() {
        isShortcutPressed = false
        shortcutPressStartTime = nil
        isHandsFreeRecording = false
        activeRecordingShortcutAction = nil
        interruptedRecordingActions.removeAll()
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
        clearPendingDoubleTaps()
        clearPendingFirstTap()
        ignoresNextShortcutUp = false
    }

    private func clearPendingFirstTap() {
        pendingFirstTapTimeout?.cancel()
        pendingFirstTapTimeout = nil
        pendingFirstTapAction = nil
    }

    /// A lone quick tap starts recording; if no second tap follows, throw that recording away.
    private func schedulePendingFirstTapTimeout(for action: ShortcutAction) {
        pendingFirstTapTimeout?.cancel()
        pendingFirstTapAction = action
        pendingFirstTapTimeout = Task { @MainActor [weak self, secondTapWindow] in
            try? await Task.sleep(nanoseconds: UInt64(secondTapWindow * 1_000_000_000))
            guard !Task.isCancelled, let self, self.pendingFirstTapAction == action else { return }
            self.pendingFirstTapAction = nil
            self.pendingFirstTapTimeout = nil
            guard !self.isShortcutPressed, self.isRecorderVisible() else { return }
            await self.cancelRecording()
        }
    }

    func clearPendingDoubleTaps() {
        pendingDoubleTapReleaseTimes.removeAll()
    }

    func clearPendingDoubleTap(for action: ShortcutAction) {
        pendingDoubleTapReleaseTimes.removeValue(forKey: action)
    }

    func clearPendingModeDoubleTaps() {
        pendingDoubleTapReleaseTimes = pendingDoubleTapReleaseTimes.filter { action, _ in
            if case .mode = action { return false }
            return true
        }
    }

    func resetShortcutState(for action: ShortcutAction) {
        pendingDoubleTapReleaseTimes.removeValue(forKey: action)
        if pendingFirstTapAction == action {
            clearPendingFirstTap()
        }
        guard activeRecordingShortcutAction == action else { return }
        ignoresNextShortcutUp = false
        isShortcutPressed = false
        shortcutPressStartTime = nil
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
    }

    func handleShortcutDown(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        if interruptedRecordingActions.remove(action) != nil {
            return
        }

        if mode == .doubleTap && (!canHandleShortcutAction() || recordingState() == .starting) {
            clearPendingDoubleTap(for: action)
            return
        }

        if mode != .doubleTap, mode != .holdOrDoubleTap, let lastTrigger = lastShortcutPressTime,
            Date().timeIntervalSince(lastTrigger) < shortcutPressCooldown
        {
            return
        }

        guard !isShortcutPressed else {
            return
        }
        isShortcutPressed = true
        activeRecordingShortcutAction = action
        activeShortcutIsDoubleTap = mode == .doubleTap
        activeShortcutCanCancelAccidentalStart = mode != .doubleTap && canCurrentShortcutPressCancelAccidentalStart
        if mode != .doubleTap {
            lastShortcutPressTime = Date()
        }
        shortcutPressStartTime = eventTime

        switch mode {
        case .toggle, .hybrid:
            if isHandsFreeRecording {
                isHandsFreeRecording = false
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
                return
            }

            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .pushToTalk:
            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .holdOrDoubleTap:
            if isHandsFreeRecording && isRecorderVisible() {
                // Any press ends a hands-free recording; its release does nothing.
                isHandsFreeRecording = false
                ignoresNextShortcutUp = true
                clearPendingFirstTap()
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
                return
            }
            isHandsFreeRecording = false

            if pendingFirstTapAction == action {
                // Second tap: lock the recording on as the key goes down, so the pill glows while it is
                // still held. How long this press lasts no longer matters; its release does nothing.
                clearPendingFirstTap()
                isHandsFreeRecording = isRecorderVisible()
                ignoresNextShortcutUp = true
                return
            }

            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .doubleTap:
            break
        }
    }

    func handleShortcutUp(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else { return }
        isShortcutPressed = false
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false

        switch mode {
        case .toggle:
            isHandsFreeRecording = true

        case .pushToTalk:
            if isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .holdOrDoubleTap:
            if ignoresNextShortcutUp {
                ignoresNextShortcutUp = false
                break
            }
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            let handlingDelay = ProcessInfo.processInfo.systemUptime - eventTime
            logger.notice(
                "Hold-or-double-tap release: pressed \(pressDuration, format: .fixed(precision: 3), privacy: .public)s, handled \(handlingDelay, format: .fixed(precision: 3), privacy: .public)s after the key moved"
            )
            clearPendingFirstTap()

            if pressDuration >= holdPressThreshold {
                // Held: push to talk, so stop and transcribe now.
                if isRecorderVisible() {
                    guard canHandleShortcutAction() else { break }
                    await toggleRecorderPanel(modeId)
                }
            } else if isRecorderVisible() {
                // First quick tap: wait briefly for a second one.
                schedulePendingFirstTapTimeout(for: action)
            }

        case .hybrid:
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            if pressDuration >= hybridPressThreshold && recordingState() == .recording {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            } else {
                isHandsFreeRecording = true
            }

        case .doubleTap:
            guard canHandleShortcutAction(), recordingState() != .starting else {
                clearPendingDoubleTap(for: action)
                break
            }
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            if pressDuration < 0 || pressDuration > doubleTapThreshold {
                pendingDoubleTapReleaseTimes.removeValue(forKey: action)
            } else if let firstRelease = pendingDoubleTapReleaseTimes.removeValue(forKey: action),
                eventTime - firstRelease >= 0,
                eventTime - firstRelease <= doubleTapThreshold
            {
                await toggleRecorderPanel(modeId)
                isHandsFreeRecording = isRecorderVisible()
            } else {
                pendingDoubleTapReleaseTimes[action] = eventTime
            }
        }

        shortcutPressStartTime = nil
    }

    func handleInterruption(action: ShortcutAction) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            if canCurrentShortcutPressCancelAccidentalStart {
                interruptedRecordingActions.insert(action)
            }
            return
        }

        if activeShortcutIsDoubleTap {
            isShortcutPressed = false
            shortcutPressStartTime = nil
            activeRecordingShortcutAction = nil
            activeShortcutCanCancelAccidentalStart = false
            activeShortcutIsDoubleTap = false
            pendingDoubleTapReleaseTimes.removeValue(forKey: action)
            return
        }

        guard activeShortcutCanCancelAccidentalStart else { return }

        reset()
        await cancelRecording()
    }

    private var canCurrentShortcutPressCancelAccidentalStart: Bool {
        !isRecorderVisible() && recordingState() == .idle
    }
}
