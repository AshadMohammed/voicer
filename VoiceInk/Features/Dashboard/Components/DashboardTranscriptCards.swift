import SwiftUI

struct DashboardTranscriptCards: View {
    let transcriptions: [Transcription]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent")
                    .font(.appSerif(21))
                    .foregroundStyle(AppTheme.Palette.ink)
                Spacer()
                Button("All history") {
                    NotificationCenter.default.post(
                        name: .navigateToDestination,
                        object: nil,
                        userInfo: ["destination": "History"]
                    )
                }
                .buttonStyle(.plain)
                .font(.appSans(13, weight: .medium))
                .foregroundStyle(AppTheme.Palette.accent)
            }

            VStack(spacing: 0) {
                ForEach(Array(transcriptions.enumerated()), id: \.element.id) { index, transcription in
                    DashboardTranscriptCardRow(transcription: transcription)

                    if index < transcriptions.count - 1 {
                        Rectangle()
                            .fill(AppTheme.Palette.line)
                            .frame(height: 1)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
            .appSurfaceCard()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DashboardTranscriptCardRow: View {
    private static let iconFrameSize: CGFloat = 30
    private static let rowSpacing: CGFloat = 12
    private static let copyButtonSize: CGFloat = 28
    private static let copyButtonTopInset: CGFloat = 12
    private static let copyButtonTrailingInset: CGFloat = 6

    let transcription: Transcription
    @State private var isHovering = false
    @State private var isExpanded = false

    private var previewText: String {
        Self.normalizedPreviewText(displayText)
    }

    private var copyText: String {
        displayText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayText: String {
        if let enhancedText = transcription.enhancedText,
            Self.isUsableEnhancedText(enhancedText)
        {
            return enhancedText
        }

        return transcription.text
    }

    private var metadataText: String {
        transcription.timestamp.formatted(.relative(presentation: .named))
    }

    private var shortTimeText: String {
        let elapsed = Date().timeIntervalSince(transcription.timestamp)
        if elapsed < 60 { return String(localized: "Just now") }
        if elapsed < 3600 { return String(localized: "\(Int(elapsed / 60)) min") }
        if elapsed < 86_400 { return String(localized: "\(Int(elapsed / 3600)) hr") }
        return transcription.timestamp.formatted(.dateTime.day().month(.abbreviated))
    }

    private var detailText: String {
        let words = copyText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let seconds = Int(transcription.duration.rounded())
        let duration = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return "\(duration) · \(Formatters.formattedNumber(words)) \(words == 1 ? String(localized: "word") : String(localized: "words"))"
    }

    private var modeIcon: ModeIcon {
        guard let iconValue = transcription.modeEmoji?.trimmingCharacters(in: .whitespacesAndNewlines),
            !iconValue.isEmpty
        else {
            return .symbol("doc.text")
        }

        if Self.isLikelySymbolName(iconValue) {
            return .symbol(iconValue)
        }

        return .emoji(iconValue)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            rowContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 13)
                .padding(.leading, 16)
                .padding(.trailing, 44)
                .background(isHovering ? Color.white.opacity(0.5) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    isExpanded.toggle()
                }
                .accessibilityAddTraits(.isButton)

            CopyIconButton(textToCopy: copyText, accessibilityLabel: "Copy transcript")
                .frame(width: Self.copyButtonSize, height: Self.copyButtonSize)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .padding(.top, Self.copyButtonTopInset)
                .padding(.trailing, Self.copyButtonTrailingInset)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transcript from \(metadataText)")
        .accessibilityValue(isExpanded ? copyText : previewText)
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(verbatim: shortTimeText)
                .font(.appNumber(12, weight: .regular))
                .foregroundStyle(AppTheme.Palette.muted)
                .frame(width: 60, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(isExpanded ? copyText : previewText)
                    .font(.appSans(13.5))
                    .foregroundStyle(AppTheme.Palette.ink)
                    .lineSpacing(2)
                    .lineLimit(isExpanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(verbatim: detailText)
                    .font(.appSans(11.5))
                    .foregroundStyle(AppTheme.Palette.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
    }

    private static func isUsableEnhancedText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        return trimmed.range(of: "Enhancement failed:", options: [.caseInsensitive, .anchored]) == nil
    }

    private static func normalizedPreviewText(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func isLikelySymbolName(_ value: String) -> Bool {
        let symbolNameCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._")

        return value.unicodeScalars.allSatisfy { scalar in
            symbolNameCharacters.contains(scalar)
        }
    }
}
