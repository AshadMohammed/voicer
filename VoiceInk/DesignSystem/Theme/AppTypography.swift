import AppKit
import CoreText
import SwiftUI

/// Voicer's typefaces: DM Sans for the interface, DM Serif Display for page titles and Space Grotesk for numbers.
/// All three ship inside the app (SIL Open Font License, see Resources/Fonts) and are registered at launch.
enum AppFonts {
    static let sans = "DM Sans"
    static let serif = "DM Serif Display"
    static let numeric = "Space Grotesk"

    private static let files = ["DMSans", "DMSerifDisplay-Regular", "SpaceGrotesk"]
    private(set) static var isRegistered = false

    static func register() {
        guard !isRegistered else { return }
        for name in files {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        isRegistered = NSFont(name: sans, size: 13) != nil
    }
}

extension Font {
    /// Page titles.
    static func appSerif(_ size: CGFloat) -> Font {
        AppFonts.isRegistered ? .custom(AppFonts.serif, size: size) : systemFallback(size, .semibold)
    }

    /// Stats, counts, durations and other numbers.
    static func appNumber(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        guard AppFonts.isRegistered else { return systemFallback(size, weight).monospacedDigit() }
        return Font.custom(AppFonts.numeric, size: size).weight(weight).monospacedDigit()
    }

    static func appSans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard AppFonts.isRegistered else { return systemFallback(size, weight) }
        return Font.custom(AppFonts.sans, size: size).weight(weight)
    }

    // The app sets fonts with `.system(size:weight:design:)` and the text styles in hundreds of places. These
    // shadow SwiftUI's versions inside this module, so every one of them draws in Voicer's typefaces without
    // touching each call site. Rounded and default become DM Sans, monospaced becomes Space Grotesk, serif
    // becomes DM Serif Display.
    static func system(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        switch design {
        case .monospaced?:
            return appNumber(size, weight: weight ?? .regular)
        case .serif?:
            return appSerif(size)
        default:
            return appSans(size, weight: weight ?? .regular)
        }
    }

    static var largeTitle: Font { textStyle(26, .regular, .largeTitle) }
    static var title: Font { textStyle(22, .regular, .title) }
    static var title2: Font { textStyle(17, .regular, .title2) }
    static var title3: Font { textStyle(15, .regular, .title3) }
    static var headline: Font { textStyle(13, .semibold, .headline) }
    static var subheadline: Font { textStyle(11, .regular, .subheadline) }
    static var body: Font { textStyle(13, .regular, .body) }
    static var callout: Font { textStyle(12, .regular, .callout) }
    static var footnote: Font { textStyle(10, .regular, .footnote) }
    static var caption: Font { textStyle(10, .regular, .caption) }
    static var caption2: Font { textStyle(10, .regular, .caption2) }

    private static func textStyle(_ size: CGFloat, _ weight: Font.Weight, _ style: Font.TextStyle) -> Font {
        AppFonts.isRegistered ? appSans(size, weight: weight) : Font.system(style).weight(weight)
    }

    /// The shadowed `system(size:)` can't call SwiftUI's own, so the fallback builds the system font directly.
    private static func systemFallback(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        let nsWeight: NSFont.Weight
        switch weight {
        case .ultraLight: nsWeight = .ultraLight
        case .thin: nsWeight = .thin
        case .light: nsWeight = .light
        case .medium: nsWeight = .medium
        case .semibold: nsWeight = .semibold
        case .bold: nsWeight = .bold
        case .heavy: nsWeight = .heavy
        case .black: nsWeight = .black
        default: nsWeight = .regular
        }
        return Font(NSFont.systemFont(ofSize: size, weight: nsWeight))
    }
}
