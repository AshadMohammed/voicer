import CoreGraphics

enum DashboardLayout {
    static let sectionSpacing: CGFloat = 24
    static let columnSpacing: CGFloat = 18
    static let pageHorizontalPadding: CGFloat = 40
    static let pageVerticalPadding: CGFloat = 40
    static let contentBottomOffset: CGFloat = 56
    static let footerTopSpacing: CGFloat = 20
    static let footerButtonHeight: CGFloat = 36
    static let cardCornerRadius: CGFloat = 16

    static func contentWidth(for availableWidth: CGFloat) -> CGFloat {
        max(0, availableWidth - (pageHorizontalPadding * 2))
    }
}
