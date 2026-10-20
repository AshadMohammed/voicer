import AppKit
import SwiftUI

/// Displays call-detection prompts in a floating panel that matches the meeting indicator style.
@MainActor
final class CallPromptPanelController {
    static let shared = CallPromptPanelController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<CallPromptView>?

    private init() {}

    /// Shows (or replaces) the prompt. `belowIndicator`: place it just under the meeting pill
    /// instead of in its spot (used for end-of-call prompts while recording).
    func show(
        message: String,
        primaryTitle: String,
        secondaryTitle: String,
        belowIndicator: Bool,
        onPrimary: @escaping () -> Void,
        onSecondary: @escaping () -> Void
    ) {
        let view = CallPromptView(
            message: message,
            primaryTitle: primaryTitle,
            secondaryTitle: secondaryTitle,
            onPrimary: onPrimary,
            onSecondary: onSecondary
        )

        if let panel, let hostingView {
            hostingView.rootView = view
            let fitted = hostingView.fittingSize
            let panelSize = NSSize(width: fitted.width + 24, height: fitted.height + 24)
            hostingView.frame = NSRect(x: 12, y: 12, width: fitted.width, height: fitted.height)
            let origin = Self.panelOrigin(size: panelSize, belowIndicator: belowIndicator)
            panel.setContentSize(panelSize)
            panel.setFrameOrigin(origin)
            panel.orderFrontRegardless()
        } else {
            let hosting = NSHostingView(rootView: view)
            let fitted = hosting.fittingSize
            // Leave room around the content for the shadow.
            let panelSize = NSSize(width: fitted.width + 24, height: fitted.height + 24)
            hosting.frame = NSRect(x: 12, y: 12, width: fitted.width, height: fitted.height)

            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.canHide = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isMovableByWindowBackground = true
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false

            let wrapper = NSView(frame: NSRect(origin: .zero, size: panelSize))
            wrapper.addSubview(hosting)
            p.contentView = wrapper

            let origin = Self.panelOrigin(size: panelSize, belowIndicator: belowIndicator)
            p.setFrameOrigin(origin)
            p.orderFrontRegardless()

            self.panel = p
            self.hostingView = hosting
        }

        panel?.accessibilityLabel = message
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    // MARK: - Positioning

    /// Top right of the main screen's visible frame. Same spot as the meeting pill when
    /// `belowIndicator` is false; directly under the pill's 60-pt-tall panel when true.
    private static func panelOrigin(size: NSSize, belowIndicator: Bool) -> NSPoint {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let frame = screen.visibleFrame
        let x = frame.maxX - size.width - 10
        let y: CGFloat
        if belowIndicator {
            // Below the meeting indicator pill (60 pt tall + 4 pt margin).
            y = frame.maxY - 60 - 4 - size.height - 4
        } else {
            y = frame.maxY - size.height - 4
        }
        return NSPoint(x: x, y: y)
    }
}

// MARK: - SwiftUI view

private struct CallPromptView: View {
    let message: String
    let primaryTitle: String
    let secondaryTitle: String
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.appSans(13, weight: .semibold))
                .foregroundStyle(AppTheme.Palette.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(secondaryTitle, action: onSecondary)
                    .buttonStyle(DashboardQuietButtonStyle())
                    .controlSize(.small)
                Button(primaryTitle, action: onPrimary)
                    .buttonStyle(MeetingAccentButtonStyle())
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.Palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppTheme.Palette.lineStrong, lineWidth: 1)
        )
        .shadow(color: AppTheme.Palette.ink.opacity(0.18), radius: 8, y: 3)
    }
}
