import SwiftUI

/// One number on the dashboard: a small label, the figure in Space Grotesk, and a line of context under it.
struct DashboardStatCard: View {
    let title: LocalizedStringKey
    let value: String
    var unit: String?
    let detail: String
    var isHighlighted = false
    var detailIsPositive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppSectionLabel(title)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value)
                    .font(.appNumber(27))
                    .foregroundStyle(AppTheme.Palette.ink)
                if let unit {
                    Text(verbatim: unit)
                        .font(.appNumber(15, weight: .regular))
                        .foregroundStyle(AppTheme.Palette.muted)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.top, 8)

            Text(verbatim: detail)
                .font(.appSans(12))
                .foregroundStyle(detailIsPositive ? AppTheme.Palette.olive : AppTheme.Palette.muted)
                .lineLimit(1)
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if isHighlighted {
                Rectangle()
                    .fill(AppTheme.Palette.accent)
                    .frame(height: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .appSurfaceCard()
    }
}

/// Words dictated on each of the last seven days, today in the accent colour.
struct DashboardWeekBarsCard: View {
    let points: [DashboardProductivityPoint]

    private var total: Int { points.reduce(0) { $0 + $1.words } }
    private var maxWords: Int { max(points.map(\.words).max() ?? 0, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                AppSectionLabel("Words this week")
                Spacer()
                Text(verbatim: String(localized: "\(Formatters.formattedNumber(total)) total"))
                    .font(.appSans(12))
                    .foregroundStyle(AppTheme.Palette.muted)
            }

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(points) { point in
                    let isToday = Calendar.current.isDateInToday(point.date)
                    VStack(spacing: 6) {
                        GeometryReader { geometry in
                            VStack {
                                Spacer(minLength: 0)
                                UnevenRoundedRectangle(
                                    topLeadingRadius: 5, bottomLeadingRadius: 2,
                                    bottomTrailingRadius: 2, topTrailingRadius: 5,
                                    style: .continuous
                                )
                                .fill(isToday ? AppTheme.Palette.accent : AppTheme.Palette.tan.opacity(0.55))
                                .frame(height: barHeight(point.words, in: geometry.size.height))
                            }
                            .frame(maxWidth: 26)
                            .frame(maxWidth: .infinity)
                        }
                        Text(point.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.appNumber(11, weight: .regular))
                            .foregroundStyle(isToday ? AppTheme.Palette.inkSoft : AppTheme.Palette.faint)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "\(point.accessibilityLabel): \(point.words)"))
                }
            }
            .frame(height: 92)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurfaceCard()
    }

    private func barHeight(_ words: Int, in height: CGFloat) -> CGFloat {
        guard words > 0 else { return 3 }
        return max(6, height * CGFloat(words) / CGFloat(maxWords))
    }
}

/// The shortcuts in use right now, so new gestures are easy to remember.
struct DashboardShortcutsCard: View {
    let primaryMode: RecordingShortcutManager.Mode

    private struct Row: Identifiable {
        let id: String
        let title: String
        /// Used when the full title doesn't fit beside the keys.
        let shortTitle: String
        let keys: String
    }

    private var rows: [Row] {
        var rows: [Row] = []
        if let primary = ShortcutStore.shortcut(for: .primaryRecording) {
            let keys = primary.displayTokens.joined(separator: " ")
            switch primaryMode {
            case .holdOrDoubleTap:
                rows.append(Row(id: "hold", title: String(localized: "Hold to talk"), shortTitle: String(localized: "Dictate"), keys: keys))
                let tapKeys = primary.kind == .modifierOnly
                    ? (primary.displayTokens.last.map { Self.symbolOnly($0) } ?? keys)
                    : keys
                rows.append(Row(id: "lock", title: String(localized: "Lock hands-free"), shortTitle: String(localized: "Hands-free"), keys: "\(tapKeys) \(tapKeys)"))
            case .pushToTalk:
                rows.append(Row(id: "hold", title: String(localized: "Hold to talk"), shortTitle: String(localized: "Dictate"), keys: keys))
            case .doubleTap:
                rows.append(Row(id: "double", title: String(localized: "Start or stop"), shortTitle: String(localized: "Dictate"), keys: "\(keys) \(keys)"))
            case .toggle, .hybrid:
                rows.append(Row(id: "toggle", title: String(localized: "Start or stop"), shortTitle: String(localized: "Dictate"), keys: keys))
            }
        }

        let extras: [(ShortcutAction, String, String)] = [
            (.pasteLastTranscription, String(localized: "Paste last transcript"), String(localized: "Paste last")),
            (.pasteLastEnhancement, String(localized: "Paste last enhanced"), String(localized: "Paste enhanced")),
            (.retryLastTranscription, String(localized: "Retry last transcript"), String(localized: "Retry last")),
            (.openQuickHistory, String(localized: "Quick history"), String(localized: "History")),
        ]
        for (action, title, shortTitle) in extras {
            if let shortcut = ShortcutStore.shortcut(for: action) {
                rows.append(Row(id: title, title: title, shortTitle: shortTitle, keys: shortcut.displayTokens.joined(separator: " ")))
            }
        }
        return Array(rows.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionLabel("Shortcuts")

            if rows.isEmpty {
                Text("Set a shortcut in Settings to start dictating.")
                    .font(.appSans(13))
                    .foregroundStyle(AppTheme.Palette.muted)
            }

            ForEach(rows) { row in
                HStack(spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        rowLabel(row.title)
                        rowLabel(row.shortTitle)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    KeyCap(text: row.keys)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .appSurfaceCard()
    }

    private func rowLabel(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.appSans(13))
            .foregroundStyle(AppTheme.Palette.inkSoft)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// "Right ⌥" becomes "⌥" when the key is shown twice in a row.
    private static func symbolOnly(_ token: String) -> String {
        token.split(separator: " ").last.map(String.init) ?? token
    }
}

struct KeyCap: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.appNumber(12))
            .foregroundStyle(AppTheme.Palette.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(AppTheme.Palette.lineStrong, lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.Palette.lineStrong)
                    .frame(height: 1)
                    .padding(.horizontal, 3)
            }
            .fixedSize()
    }
}
