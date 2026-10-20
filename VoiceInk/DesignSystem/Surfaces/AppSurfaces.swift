import SwiftUI

struct AppCardBackground: View {
    var isSelected: Bool = false
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(AppTheme.Surface.card)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        isSelected ? AppTheme.Selection.border : AppTheme.Border.subtle,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
    }
}

struct AppMaterialCardBackground: View {
    var isSelected: Bool = false
    var cornerRadius: CGFloat = 12

    static let fill = AppTheme.Surface.materialCard

    static func border(for isSelected: Bool) -> Color {
        isSelected ? AppTheme.Selection.border : AppTheme.Border.card
    }

    static func lineWidth(for isSelected: Bool) -> CGFloat {
        isSelected ? 1.5 : 1
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Self.fill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        Self.border(for: isSelected),
                        lineWidth: Self.lineWidth(for: isSelected)
                    )
            )
    }
}

struct MetricTintBackground: View {
    let color: Color
    var cornerRadius: CGFloat = AppTheme.Radius.card

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: color.opacity(0.15), location: 0),
                        .init(color: AppTheme.Surface.window.opacity(0.1), location: 0.6),
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                AppTheme.Border.subtle,
                                AppTheme.Border.subtle.opacity(0.4),
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.05), radius: 5, y: 3)
    }
}

/// The cream page behind every screen, with the faint dot grid from the Fin dashboard.
struct AppPaperBackground: View {
    var showsDotGrid = true

    var body: some View {
        ZStack {
            AppTheme.Palette.paper
            if showsDotGrid {
                Canvas { context, size in
                    let spacing: CGFloat = 20
                    let dot = Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2))
                    var y: CGFloat = spacing / 2
                    while y < size.height {
                        var x: CGFloat = spacing / 2
                        while x < size.width {
                            context.fill(dot.offsetBy(dx: x, dy: y), with: .color(AppTheme.Palette.dotGrid))
                            x += spacing
                        }
                        y += spacing
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A flat cream card with a hairline border, the building block of every screen.
struct AppSurfaceCard: ViewModifier {
    var cornerRadius: CGFloat = AppTheme.Radius.card
    var fill: Color = AppTheme.Palette.card

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AppTheme.Palette.line, lineWidth: 1)
            )
    }
}

extension View {
    func appSurfaceCard(cornerRadius: CGFloat = AppTheme.Radius.card, fill: Color = AppTheme.Palette.card) -> some View {
        modifier(AppSurfaceCard(cornerRadius: cornerRadius, fill: fill))
    }

    /// A grouped form drawn on the cream page instead of the system grey.
    func appGroupedForm() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }
}

/// Small spaced capitals above a group: "OVERVIEW", "SHORTCUTS".
struct AppSectionLabel: View {
    private let text: Text

    init(_ title: LocalizedStringKey) {
        text = Text(title)
    }

    init(verbatim title: String) {
        text = Text(verbatim: title)
    }

    var body: some View {
        text
            .font(.appSans(10.5, weight: .medium))
            .tracking(1.1)
            .textCase(.uppercase)
            .foregroundStyle(AppTheme.Palette.muted)
    }
}

/// Eyebrow plus serif title at the top of a screen.
struct AppPageHeader<Trailing: View>: View {
    let eyebrow: LocalizedStringKey
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                AppSectionLabel(eyebrow)
                Text(title)
                    .font(.appSerif(32))
                    .foregroundStyle(AppTheme.Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let subtitle {
                    Text(subtitle)
                        .font(.appSans(13.5))
                        .foregroundStyle(AppTheme.Palette.muted)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension AppPageHeader where Trailing == EmptyView {
    init(eyebrow: LocalizedStringKey, title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = { EmptyView() }
    }
}
