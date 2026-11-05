import AppKit
import Combine
import SwiftUI

/// What the meeting pill is showing, shared between the panel and its view.
@MainActor
final class MeetingPillModel: ObservableObject {
    /// The mouse is over the pill, so the controls are showing.
    @Published var isHovering = false
    /// Folded into a small tab at the screen edge. The recording carries on.
    @Published var isCollapsed = false
    /// Set once the call has ended: when the recording will stop and save by itself.
    @Published var endDeadline: Date?
    var onKeepRecording: (() -> Void)?
}

/// The small "recording a meeting" pill. It stands in the middle of the right screen edge, tall and narrow:
/// the dot and the time at rest, Pause, Stop and Hide when the mouse is over it. Hide folds it into a tab.
/// When the call ends it turns into a short notice with a Keep recording button.
@MainActor
final class MeetingIndicatorController {
    static let shared = MeetingIndicatorController()

    private var panel: NSPanel?
    private let model = MeetingPillModel()
    private var modelObserver: AnyCancellable?
    private var coordinatorObserver: AnyCancellable?

    /// Room around the drawn shape for its shadow.
    private let margin: CGFloat = 12
    /// How far the pill stands in from the screen edge.
    private let edgeInset: CGFloat = 6

    private init() {}

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        model.isHovering = false
        model.isCollapsed = false
        model.endDeadline = nil

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size()),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false

        let hosting = NSHostingView(rootView: MeetingIndicatorView(coordinator: MeetingsCoordinator.shared, model: model))
        panel.contentView = hosting
        self.panel = panel

        // The panel is sized to what is showing, so a change of state is a change of size.
        modelObserver = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateFrame(animated: true) }
        coordinatorObserver = MeetingsCoordinator.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateFrame(animated: true) }
        updateFrame(animated: false)
        panel.orderFrontRegardless()
    }

    func hide() {
        modelObserver = nil
        coordinatorObserver = nil
        panel?.orderOut(nil)
        panel = nil
        model.endDeadline = nil
        model.onKeepRecording = nil
    }

    /// The call has ended: shows the notice and counts down to the automatic stop.
    func showCallEnded(deadline: Date, onKeep: @escaping () -> Void) {
        model.onKeepRecording = onKeep
        model.isCollapsed = false
        model.endDeadline = deadline
    }

    func hideCallEnded() {
        model.endDeadline = nil
        model.onKeepRecording = nil
    }

    func revealForSilenceStatus() {
        model.isCollapsed = false
    }

    // MARK: - Size and place

    /// The pill's drawn size in each state; the panel adds `margin` around it.
    private var contentSize: NSSize {
        if MeetingsCoordinator.shared.isSilencePromptShown { return NSSize(width: 252, height: 126) }
        if MeetingsCoordinator.shared.isAutoPausedForSilence { return NSSize(width: 252, height: 116) }
        if model.endDeadline != nil { return NSSize(width: 214, height: 96) }
        if MeetingsCoordinator.shared.captureProblem != nil || MeetingsCoordinator.shared.captureDeviceNotice != nil {
            return NSSize(width: 230, height: model.isHovering ? 224 : 112)
        }
        if model.isCollapsed { return NSSize(width: 20, height: 56) }
        return model.isHovering ? NSSize(width: 48, height: 182) : NSSize(width: 48, height: 66)
    }

    /// The folded tab touches the screen edge, so it needs no shadow room on its right.
    private var isTab: Bool {
        model.isCollapsed && model.endDeadline == nil
            && MeetingsCoordinator.shared.captureProblem == nil
            && MeetingsCoordinator.shared.captureDeviceNotice == nil
    }

    private func size() -> NSSize {
        NSSize(width: contentSize.width + (isTab ? margin : margin * 2), height: contentSize.height + margin * 2)
    }

    private func updateFrame(animated: Bool) {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let size = size()
        // The tab sits flush with the edge; everything else stands in a little.
        let rightEdge = isTab ? frame.maxX : frame.maxX - edgeInset + margin
        let origin = NSPoint(x: rightEdge - size.width, y: frame.midY - size.height / 2)
        let target = NSRect(origin: origin, size: size)
        guard panel.frame != target else { return }
        if animated, panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }
}

struct MeetingIndicatorView: View {
    @ObservedObject var coordinator: MeetingsCoordinator
    @ObservedObject var model: MeetingPillModel

    var body: some View {
        ZStack(alignment: .trailing) {
            if coordinator.isSilencePromptShown {
                silencePrompt
            } else if coordinator.isAutoPausedForSilence {
                autoPausedNotice
            } else if let deadline = model.endDeadline {
                endedNotice(deadline: deadline)
            } else if model.isCollapsed && statusMessage == nil {
                tab
            } else {
                pill
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, model.isCollapsed && model.endDeadline == nil && statusMessage == nil ? 0 : 12)
        .background(PillHoverTracker { model.isHovering = $0 })
        .animation(.easeOut(duration: 0.14), value: model.isHovering)
        .animation(.easeOut(duration: 0.14), value: model.isCollapsed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording a meeting")
    }

    // MARK: - The pill

    private var statusMessage: String? {
        coordinator.captureProblem ?? coordinator.captureDeviceNotice
    }

    private var pill: some View {
        VStack(spacing: 8) {
            VStack(spacing: 6) {
                RecordingDot(coordinator: coordinator)
                    .padding(.top, 2)
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    Text(elapsed(at: context.date))
                        .font(.appNumber(11.5, weight: .medium))
                        .foregroundStyle(coordinator.isPaused ? AppTheme.Palette.muted : AppTheme.Palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(height: 50)

            if let statusMessage {
                Text(statusMessage)
                    .font(.appSans(11, weight: .medium))
                    .foregroundStyle(coordinator.captureProblem == nil ? AppTheme.Palette.inkSoft : AppTheme.Palette.recording)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
            }

            if model.isHovering {
                VStack(spacing: 8) {
                    PillButton(
                        symbol: coordinator.isPaused ? "play.fill" : "pause.fill",
                        help: coordinator.isPaused ? "Resume recording" : "Pause recording"
                    ) { coordinator.togglePause() }
                    PillButton(symbol: "stop.fill", help: "Stop recording the meeting", filled: true) {
                        coordinator.stopRecording()
                    }
                    .disabled(!coordinator.isRecording)
                    PillButton(symbol: "chevron.right", help: "Hide the pill. Recording carries on.") {
                        model.isCollapsed = true
                        model.isHovering = false
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(width: statusMessage == nil ? 48 : 230)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Capsule().fill(AppTheme.Palette.card))
        .overlay(Capsule().strokeBorder(AppTheme.Palette.lineStrong, lineWidth: 1))
        .shadow(color: AppTheme.Palette.ink.opacity(0.18), radius: 8, y: 3)
        .padding(.vertical, 12)
    }

    /// The pill folded away: a small tab at the edge. A click brings the pill back.
    private var tab: some View {
        Button {
            model.isCollapsed = false
        } label: {
            VStack(spacing: 5) {
                Circle()
                    .fill(coordinator.isPaused ? AppTheme.Palette.faint : AppTheme.Palette.recording)
                    .frame(width: 7, height: 7)
                Image(systemName: "chevron.left")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AppTheme.Palette.inkSoft)
            }
            .frame(width: 20, height: 56)
            .background(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(AppTheme.Palette.card))
            .overlay(
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
                    .strokeBorder(AppTheme.Palette.lineStrong, lineWidth: 1))
            .shadow(color: AppTheme.Palette.ink.opacity(0.18), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 28, minHeight: 56)
        .help("Show the meeting pill")
        .accessibilityLabel("Show the meeting pill")
    }

    // MARK: - Call ended

    private var silencePrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing heard for 10 min. Stop recording?")
                .font(.appSans(13, weight: .semibold))
                .foregroundStyle(AppTheme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Stop") { coordinator.stopRecording() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Keep recording") { coordinator.keepRecordingAfterSilence() }
                    .buttonStyle(MeetingAccentButtonStyle())
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 252, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppTheme.Palette.lineStrong, lineWidth: 1))
        .shadow(color: AppTheme.Palette.ink.opacity(0.18), radius: 8, y: 3)
    }

    private var autoPausedNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paused after 15 min with no sound")
                .font(.appSans(13, weight: .semibold))
                .foregroundStyle(AppTheme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Stop") { coordinator.stopRecording() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Resume") { coordinator.resumeRecording() }
                    .buttonStyle(MeetingAccentButtonStyle())
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 252, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppTheme.Palette.lineStrong, lineWidth: 1))
        .shadow(color: AppTheme.Palette.ink.opacity(0.18), radius: 8, y: 3)
    }

    private func endedNotice(deadline: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let seconds = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                Text("Call ended, saving in \(seconds)s")
                    .font(.appSans(13, weight: .semibold))
                    .foregroundStyle(AppTheme.Palette.ink)
                    .lineLimit(1)
            }
            Button("Keep recording") { model.onKeepRecording?() }
                .buttonStyle(MeetingAccentButtonStyle())
                .controlSize(.small)
        }
        .padding(14)
        .frame(width: 214, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppTheme.Palette.lineStrong, lineWidth: 1))
        .shadow(color: AppTheme.Palette.ink.opacity(0.18), radius: 8, y: 3)
    }

    private func elapsed(at date: Date) -> String {
        MeetingTranscriptAssembler.timestamp(coordinator.elapsed(at: date))
    }
}

/// The recording dot. It dims a little when nobody is making a sound, and goes grey while paused.
private struct RecordingDot: View {
    @ObservedObject var coordinator: MeetingsCoordinator

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            // Speech peaks sit around 0.05–0.5; anything above a whisper counts as sound.
            let hearing = max(coordinator.microphoneLevel, coordinator.callLevel) > 0.02
            Circle()
                .fill(coordinator.isPaused ? AppTheme.Palette.faint : AppTheme.Palette.recording)
                .frame(width: 9, height: 9)
                .opacity(coordinator.isPaused || hearing ? 1 : 0.5)
                .scaleEffect(hearing && !coordinator.isPaused ? 1.15 : 1)
                .animation(.easeInOut(duration: 0.25), value: hearing)
        }
        .frame(width: 12, height: 12)
        .accessibilityLabel(coordinator.isPaused ? "Paused" : "Recording")
    }
}

private struct PillButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(filled ? AppTheme.Text.onAccent : AppTheme.Palette.inkSoft)
                .frame(width: 30, height: 30)
                .background(Circle().fill(filled ? AppTheme.Palette.accent : AppTheme.Palette.ink.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Reports whether the mouse is over the pill. The panel never becomes the key window, so SwiftUI's own
/// hover isn't relied on; this watches the mouse with a tracking area that works whatever is active.
private struct PillHoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.onChange = onChange
    }

    final class TrackerView: NSView {
        var onChange: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero,
                    options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                    owner: self,
                    userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
    }
}
