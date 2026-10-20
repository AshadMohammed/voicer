import AppKit
import Foundation
import SwiftUI

enum AppAppearancePreference: String, CaseIterable, Hashable, Identifiable {
    static let userDefaultsKey = "AppAppearancePreference"

    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return String(localized: "System")
        case .light:
            return String(localized: "Light")
        case .dark:
            return String(localized: "Dark")
        }
    }

    /// Voicer's cream design is light only, so the app always runs light whatever was saved.
    static var stored: AppAppearancePreference {
        .light
    }

    static func applyStored() {
        stored.apply()
    }

    func apply() {
        let updateAppearance = {
            NSApplication.shared.appearance = self.appKitAppearance
        }

        if Thread.isMainThread {
            updateAppearance()
        } else {
            DispatchQueue.main.async(execute: updateAppearance)
        }
    }

    var resolvedColorScheme: ColorScheme {
        switch self {
        case .system:
            let match = NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua ? .dark : .light
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    private var appKitAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }
}

private struct PopoverAppAppearanceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.preferredColorScheme(AppAppearancePreference.stored.resolvedColorScheme)
    }
}

extension View {
    func popoverAppAppearance() -> some View {
        modifier(PopoverAppAppearanceModifier())
    }
}
