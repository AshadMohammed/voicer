import SwiftUI

enum AppTheme {
    /// Voicer's light palette, shared with the Fin dashboard: cream paper, ink, warm tan, and orange as the accent.
    enum Palette {
        static let paper = rgb(0xF5F0E8)
        static let paperDeep = rgb(0xEDE7DB)
        static let card = rgb(0xFAF7F2)
        static let ink = rgb(0x2C2C2C)
        static let inkSoft = rgb(0x4A4A4A)
        static let muted = rgb(0x8B8178)
        static let faint = rgb(0xB5AFA6)
        static let tan = rgb(0xC4A882)
        static let olive = rgb(0x4A6741)
        static let line = Color(.sRGB, red: 44 / 255, green: 44 / 255, blue: 44 / 255, opacity: 0.08)
        static let lineStrong = Color(.sRGB, red: 44 / 255, green: 44 / 255, blue: 44 / 255, opacity: 0.14)
        static let accent = rgb(0xD9690B)
        /// The recorder's lock glow and live dot.
        static let recording = rgb(0xFF9500)
        static let dotGrid = Color(.sRGB, red: 74 / 255, green: 103 / 255, blue: 65 / 255, opacity: 0.11)

        static func rgb(_ hex: UInt32) -> Color {
            Color(
                .sRGB,
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255
            )
        }
    }

    enum Accent {
        static let primary = Palette.accent
        static let fillSubtle = primary.opacity(0.10)
        static let fill = primary.opacity(0.14)
        static let fillStrong = primary.opacity(0.28)
        static let border = primary.opacity(0.40)
        static let disabled = primary.opacity(0.50)
        static let foreground = primary.opacity(0.65)
        static let strong = primary.opacity(0.80)
        static let shadow = primary.opacity(0.20)
    }

    enum Surface {
        static let card = Palette.card
        static let materialCard = Palette.card
        static let subtle = Palette.ink.opacity(0.05)
        static let controlActive = Palette.ink.opacity(0.08)
        static let control = Color.white
        static let window = Palette.paper
        static let sidebar = Palette.paperDeep
        static let sidePanelOverlay = Palette.paper.opacity(0.60)
        static let clear = Color.clear
    }

    enum Border {
        static let subtle = Palette.line
        static let card = Palette.line
        static let control = Palette.lineStrong
        static let tint = Palette.line
        static let sidePanelOuter = Palette.line
    }

    enum Selection {
        static let fill = Palette.accent.opacity(0.10)
        static let border = Palette.accent.opacity(0.35)
        static let foreground = Palette.ink
    }

    enum Status {
        static let success = Color(nsColor: .alternateSelectedControlTextColor).opacity(0.85)
        static let positive = Color(nsColor: .systemGreen)
        static let info = Color(nsColor: .alternateSelectedControlTextColor).opacity(0.75)
        static let infoStrong = Color(nsColor: .systemBlue)
        static let warning = Color(nsColor: .alternateSelectedControlTextColor).opacity(0.85)
        static let warningStrong = Color(nsColor: .systemOrange)
        static let error = Color(nsColor: .systemRed)
    }

    enum Data {
        static let transcript = Palette.accent
        static let audio = Palette.tan
        static let enhancement = Palette.olive
        static let purple = Color(nsColor: .systemPurple)
        static let yellow = Color(nsColor: .systemYellow)
        static let orange = Color(nsColor: .systemOrange)
    }

    enum Insights {
        static let page = Palette.paper
        static let card = Palette.card
        static let elevated = Color.white
        static let hover = Palette.ink.opacity(0.045)
        static let border = AppTheme.Border.tint
        static let productivity = Palette.accent
        static let activity = Palette.tan
        static let selection = productivity.opacity(0.12)
        static let selectionText = Palette.accent
        static let grid = Palette.ink.opacity(0.075)
    }

    enum Sidebar {
        static let dashboard = Palette.accent
        static let modes = Palette.accent
        static let models = Palette.accent
        static let audio = Palette.accent
        static let dictionary = Palette.accent
        static let transcribeAudio = Palette.accent
        static let fallback = Palette.muted
        static let license = Palette.olive
    }

    enum Waveform {
        static let hoverBubble = Color.primary.opacity(0.74)
        static let hoverMarker = Color.primary.opacity(0.68)
        static let playedLower = Color.primary
        static let playedUpper = Color.primary.opacity(0.80)
        static let unplayedLower = Color.primary.opacity(0.30)
        static let unplayedUpper = Color.primary.opacity(0.20)
    }

    enum Text {
        static let primary = Palette.ink
        static let secondary = Palette.muted
        static let muted = Palette.faint
        static let disabled = Palette.faint
        static let onAccent = Color.white
    }

    enum NativeText {
        static let primary = NSColor.labelColor
    }

    enum Action {
        static let primaryFill = Accent.primary
        static let primaryForeground = Text.onAccent
        static let destructiveFill = Color(nsColor: .systemRed)
        static let destructiveForeground = Text.onAccent
        static let secondaryForeground = Text.primary
        static let disabledFill = Surface.controlActive
        static let disabledForeground = Text.disabled
    }

    enum Radius {
        static let control: CGFloat = 14
        static let card: CGFloat = 12
        static let pill: CGFloat = 22
    }
}
