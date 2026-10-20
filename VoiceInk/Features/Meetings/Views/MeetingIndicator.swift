import AppKit
import SwiftUI

/// The small "recording a meeting" pill. It sits at the top right of the screen, away from the dictation pill
/// at the bottom and the notch recorder at the top centre, and can be dragged anywhere.
@MainActor
final class MeetingIndicatorController {
    static let shared = MeetingIndicatorController()

    private var panel: NSPanel?
    private let size = NSSize(width: 248, height: 60)

    private init() {}

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false

        let hosting = NSHostingView(rootView: MeetingIndicatorView(coordinator: MeetingsCoordinator.shared))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 10, y: frame.maxY - size.height - 4))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct MeetingIndicatorView: View {
    @ObservedObject var coordinator: MeetingsCoordinator
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(AppTheme.Palette.recording)
                .frame(width: 9, height: 9)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }

            VStack(alignment: .leading, spacing: 1) {
                Text("Meeting")
                    .font(.appSans(11, weight: .semibold))
                    .foregroundStyle(AppTheme.Palette.inkSoft)
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    HStack(spacing: 6) {
                        Text(elapsed(at: context.date))
                            .font(.appNumber(13, weight: .medium))
                            .foregroundStyle(AppTheme.Palette.ink)
                        MeetingLevelBars(level: coordinator.microphoneLevel, help: "Your microphone")
                        MeetingLevelBars(level: coordinator.callLevel, help: "Call audio")
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                coordinator.stopRecording()
            } label: {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(AppTheme.Text.onAccent)
                        .frame(width: 8, height: 8)
                    Text("Stop")
                        .font(.appSans(12, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.onAccent)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(AppTheme.Palette.accent))
            }
            .buttonStyle(.plain)
            .help("Stop recording the meeting")
            .disabled(!coordinator.isRecording)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(width: 228, height: 40)
        .background(Capsule().fill(AppTheme.Palette.card))
        .overlay(Capsule().strokeBorder(AppTheme.Palette.lineStrong, lineWidth: 1))
        .shadow(color: AppTheme.Palette.ink.opacity(0.18), radius: 8, y: 3)
        .frame(width: 248, height: 60)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording a meeting")
    }

    private func elapsed(at date: Date) -> String {
        guard let start = coordinator.recordingStartedAt else { return "0:00" }
        return MeetingTranscriptAssembler.timestamp(max(0, date.timeIntervalSince(start)))
    }
}

/// Three tiny bars that rise with a track's level, so it's obvious both sides are being heard.
private struct MeetingLevelBars: View {
    let level: Float
    let help: LocalizedStringKey

    var body: some View {
        // Speech peaks sit around 0.05–0.5; a square root spreads that range over the bars.
        let scaled = CGFloat(min(1, sqrt(max(0, level)) * 1.4))
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<3, id: \.self) { index in
                let threshold = CGFloat(index) / 3
                Capsule()
                    .fill(scaled > threshold + 0.05 ? AppTheme.Palette.accent : AppTheme.Palette.faint.opacity(0.6))
                    .frame(width: 2.5, height: 4 + CGFloat(index) * 3)
            }
        }
        .frame(height: 10, alignment: .bottom)
        .help(help)
    }
}
