import AppKit
import SwiftUI

enum AppWindowLayout {
    static let width: CGFloat = 950
    static let minimumHeight: CGFloat = 750
}

enum AppWindowID {
    static let main = "main"
}

enum WindowDiagnostics {
    static func visibleUserFacingWindows(excluding excludedWindow: NSWindow? = nil) -> [NSWindow] {
        NSApplication.shared.windows.filter { window in
            if let excludedWindow, window == excludedWindow {
                return false
            }

            return window.isVisible && window.level == .normal && window.styleMask.contains(.titled)
        }
    }
}

enum AppPresentationPolicy {
    /// True while Voicer has been a hidden app since it last showed a window. The system adds a hidden app to the Cmd-Tab
    /// list without an activation, so Voicer lands last and a quick Cmd-Tab goes to the wrong app. The first window after
    /// that passes focus through the Dock process and back, so Voicer is registered as the app that came to the front.
    /// Electron does the same when it shows its Dock icon. The Dock has no windows and is not in the Cmd-Tab list, so
    /// nothing flickers and the app the user came from stays second.
    private static var needsActivationRegistration = UserDefaults.standard.bool(forKey: "IsMenuBarOnly")
    private static var registrationInFlight = false
    private static var isRegistering = false
    private static var registrationID = 0

    static func activateForUserFacingWindow() {
        let app = NSApplication.shared
        if app.activationPolicy() != .regular {
            app.setActivationPolicy(.regular)
        }
        // One turn after the policy switch, so the system already sees Voicer as a normal app.
        DispatchQueue.main.async {
            app.activate(ignoringOtherApps: true)
        }
        registerActivationIfNeeded()
    }

    /// Called when Voicer becomes a hidden app, so the next window registers its activation.
    static func markHiddenFromSwitcher() {
        needsActivationRegistration = true
    }

    private static func registerActivationIfNeeded() {
        guard needsActivationRegistration, !registrationInFlight else { return }
        registrationInFlight = true
        isRegistering = true
        registrationID += 1
        let id = registrationID

        // The window stays invisible while focus passes through the Dock, so the change of focus is never seen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if id == registrationID { finishRegistration() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Opened without coming to the front: a later real switch to Voicer registers it, so nothing more to do.
            needsActivationRegistration = false
            guard NSApplication.shared.isActive,
                let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
            else {
                finishRegistration()
                return
            }
            dock.activate(options: [.activateIgnoringOtherApps])

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // The user moved on to another app: leave it alone.
                let front = NSWorkspace.shared.frontmostApplication
                if front?.processIdentifier == dock.processIdentifier || front == NSRunningApplication.current {
                    // An app cannot always bring itself forward, but an open request through the system is honoured.
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if id == registrationID { finishRegistration() }
                }
            }
        }
    }

    static func hideWhileRegistering(_ window: NSWindow) {
        if isRegistering {
            window.alphaValue = 0
        }
    }

    private static func finishRegistration() {
        guard isRegistering else { return }
        isRegistering = false
        registrationInFlight = false
        for window in NSApplication.shared.windows where window.alphaValue == 0 && window.styleMask.contains(.titled) {
            window.alphaValue = 1
        }
    }

    static func restoreAccessoryIfNeededAfterUserFacingWindowClosed() {
        DispatchQueue.main.async {
            let menuBarOnly = UserDefaults.standard.bool(forKey: "IsMenuBarOnly")
            let hasVisibleUserWindows = !WindowDiagnostics.visibleUserFacingWindows().isEmpty

            guard menuBarOnly else { return }
            guard !hasVisibleUserWindows else { return }

            markHiddenFromSwitcher()
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.deactivate()
        }
    }
}

class WindowManager: NSObject {
    static let shared = WindowManager()

    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("com.ashadmohammed.voicer.mainWindow")
    private static let mainWindowAutosaveName = NSWindow.FrameAutosaveName("VoiceInkMainWindowFrame")

    private weak var mainWindow: NSWindow?
    private var didApplyInitialPlacement = false
    private var shouldShowNextConfiguredMainWindow = false

    private override init() {
        super.init()
    }

    func prepareForUserRequestedMainWindow() {
        guard !shouldShowNextConfiguredMainWindow else { return }
        shouldShowNextConfiguredMainWindow = true
    }

    func configureWindow(_ window: NSWindow) {
        if let existingWindow = NSApplication.shared.windows.first(where: {
            $0.identifier == Self.mainWindowIdentifier && $0 != window
        }) {
            window.close()
            if shouldShowNextConfiguredMainWindow {
                presentMainWindow(existingWindow)
                shouldShowNextConfiguredMainWindow = false
            } else {
                existingWindow.makeKeyAndOrderFront(nil)
            }
            return
        }

        let requiredStyleMask: NSWindow.StyleMask = [
            .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
        ]
        window.styleMask.formUnion(requiredStyleMask)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.title = "Voicer"
        window.collectionBehavior = [.fullScreenPrimary]
        window.level = .normal
        window.isOpaque = false
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: AppWindowLayout.width, height: AppWindowLayout.minimumHeight)
        window.maxSize = NSSize(width: AppWindowLayout.width, height: CGFloat.greatestFiniteMagnitude)
        window.setFrameAutosaveName(Self.mainWindowAutosaveName)
        applyInitialPlacementIfNeeded(to: window)
        registerMainWindowIfNeeded(window)
        AppPresentationPolicy.hideWhileRegistering(window)

        if shouldShowNextConfiguredMainWindow {
            shouldShowNextConfiguredMainWindow = false
            presentMainWindow(window)
        } else if UserDefaults.standard.bool(forKey: "IsMenuBarOnly") {
            window.orderOut(nil)
        }
    }

    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.identifier = Self.mainWindowIdentifier
        window.delegate = self
    }

    @discardableResult
    func showMainWindow() -> NSWindow? {
        guard let window = resolveMainWindow() else {
            return nil
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        presentMainWindow(window)
        return window
    }

    func hideMainWindow() {
        guard let window = resolveMainWindow() else {
            return
        }

        window.orderOut(nil)
    }

    func currentMainWindow() -> NSWindow? {
        resolveMainWindow()
    }

    private func registerMainWindowIfNeeded(_ window: NSWindow) {
        if window.identifier == nil || window.identifier != Self.mainWindowIdentifier {
            registerMainWindow(window)
        }
    }

    private func applyInitialPlacementIfNeeded(to window: NSWindow) {
        guard !didApplyInitialPlacement else { return }
        // Attempt to restore previous frame if one exists; otherwise fall back to a centered placement
        if window.setFrameUsingName(Self.mainWindowAutosaveName) {
            enforceMainWindowFrameIfNeeded(on: window, preserveRestoredOrigin: true)
        } else {
            enforceMainWindowFrameIfNeeded(on: window, preserveRestoredOrigin: false)
            window.center()
        }
        didApplyInitialPlacement = true
    }

    private func enforceMainWindowFrameIfNeeded(on window: NSWindow, preserveRestoredOrigin: Bool) {
        let currentFrame = window.frame
        guard currentFrame.width != AppWindowLayout.width || currentFrame.height < AppWindowLayout.minimumHeight else {
            return
        }

        let height = max(currentFrame.height, AppWindowLayout.minimumHeight)
        let x = preserveRestoredOrigin ? currentFrame.origin.x : currentFrame.midX - (AppWindowLayout.width / 2)
        let frame = NSRect(
            x: x,
            y: currentFrame.maxY - height,
            width: AppWindowLayout.width,
            height: height
        )
        window.setFrame(frame, display: true)
    }

    private func resolveMainWindow() -> NSWindow? {
        if let window = mainWindow {
            return window
        }

        if let window = NSApplication.shared.windows.first(where: { $0.identifier == Self.mainWindowIdentifier }) {
            mainWindow = window
            window.delegate = self
            return window
        }

        return nil
    }

    private func presentMainWindow(_ window: NSWindow) {
        AppPresentationPolicy.activateForUserFacingWindow()
        AppPresentationPolicy.hideWhileRegistering(window)

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if !window.isKeyWindow {
            window.orderFrontRegardless()
        }
    }
}

extension WindowManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window.identifier == Self.mainWindowIdentifier {
            mainWindow = nil
            didApplyInitialPlacement = false
        }
    }
}
