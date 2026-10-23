import Foundation

/// Opens a main-window tab from contexts with no view hierarchy, such as a notification action.
enum ModeSetupNavigator {
    /// The Modes and AI Models pages are gone; the speech model now lives in Settings.
    static func openModesSettings() {
        MainWindowNavigator.open(destination: .settings)
    }

    static func openModelsSettings() {
        MainWindowNavigator.open(destination: .settings)
    }
}

enum AudioSetupNavigator {
    static func openAudioSettings() {
        MainWindowNavigator.open(destination: .audio)
    }
}

private enum MainWindowNavigator {
    static func open(destination: ViewType) {
        MainWindowNavigation.shared.navigate(to: destination)

        if WindowManager.shared.currentMainWindow() == nil {
            WindowManager.shared.prepareForUserRequestedMainWindow()
            NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
        } else {
            WindowManager.shared.showMainWindow()
        }
    }
}
