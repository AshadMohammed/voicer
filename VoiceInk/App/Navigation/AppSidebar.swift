import SwiftUI

struct AppSidebar: View {
    let selectedView: ViewType
    let onSelect: (ViewType) -> Void
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @ObservedObject private var modeManager = ModeManager.shared

    var body: some View {
        ZStack(alignment: .trailing) {
            sidebarBackground
            sidebarDivider
            sidebarContent
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .onAppear {
            ViewType.assertSidebarItemsCoverAllCases()
        }
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VoicerWordmark()
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)

            sidebarSection(ViewType.primaryItems)

            Spacer(minLength: 16)

            sidebarSection(ViewType.secondaryItems)

            modelStatus
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sidebarBackground: some View {
        AppTheme.Surface.sidebar
            .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebarDivider: some View {
        Rectangle()
            .fill(AppTheme.Palette.line)
            .frame(width: 1)
            .ignoresSafeArea(.container, edges: .top)
    }

    private var modelStatus: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(AppTheme.Palette.olive)
                    .frame(width: 7, height: 7)
                Text("Ready")
                    .font(.appSans(12, weight: .semibold))
                    .foregroundStyle(AppTheme.Palette.inkSoft)
            }
            Text(activeModelName ?? String(localized: "No model selected"))
                .font(.appSans(12))
                .foregroundStyle(AppTheme.Palette.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.4))
        )
    }

    /// The model the current mode records with, which is what a dictation actually uses.
    private var activeModelName: String? {
        if let key = modeManager.currentEffectiveConfiguration?.selectedTranscriptionModelName,
            let model = TranscriptionModelRegistry.model(forSelectionKey: key, in: transcriptionModelManager.allAvailableModels)
                ?? TranscriptionModelRegistry.model(forSelectionKey: key, in: TranscriptionModelRegistry.models)
        {
            return model.displayName
        }
        return transcriptionModelManager.currentTranscriptionModel?.displayName
    }

    private func sidebarSection(_ items: [ViewType]) -> some View {
        VStack(spacing: 2) {
            ForEach(items) { viewType in
                SidebarItemButton(
                    viewType: viewType,
                    isSelected: selectedView == viewType
                ) {
                    onSelect(viewType)
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

/// The recorder pill in miniature, next to the name: the same mark as the app icon.
private struct VoicerWordmark: View {
    private let barHeights: [CGFloat] = [5, 8, 10, 8, 5]

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Array(barHeights.enumerated()), id: \.offset) { index, height in
                    Capsule()
                        .fill(index == 2 ? AppTheme.Palette.recording : Color.white)
                        .frame(width: 2, height: height)
                }
            }
            .frame(width: 26, height: 15)
            .background(Capsule().fill(Color.black))

            Text(verbatim: "Voicer")
                .font(.appSerif(21))
                .foregroundStyle(AppTheme.Palette.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voicer")
    }
}

private extension ViewType {
    var title: LocalizedStringKey {
        switch self {
        case .transcribeAudio:
            return "Transcribe"
        default:
            return LocalizedStringKey(rawValue)
        }
    }

    static let primaryItems: [ViewType] = [
        .dashboard,
        .transcribeAudio,
        .history,
        .meetings,
        .dictionary,
        .audio,
    ]

    // The license page is left out: this build is always licensed.
    static let secondaryItems: [ViewType] = [
        .settings,
    ]

    static func assertSidebarItemsCoverAllCases() {
        #if DEBUG
            let sidebarItems = primaryItems + secondaryItems
            let listedCases = allCases.filter { $0 != .license }
            assert(Set(sidebarItems) == Set(listedCases) && sidebarItems.count == listedCases.count)
        #endif
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .transcribeAudio: return "waveform"
        case .history: return "clock"
        case .meetings: return "person.2"
        case .audio: return "mic"
        case .dictionary: return "character.book.closed"
        case .settings: return "gearshape"
        case .license: return "checkmark.seal"
        }
    }
}

private struct SidebarItemButton: View {
    let viewType: ViewType
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: viewType.icon)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(isSelected ? AppTheme.Palette.accent : AppTheme.Palette.muted)
                    .frame(width: 18)

                Text(viewType.title)
                    .font(.appSans(14, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? AppTheme.Palette.ink : AppTheme.Palette.inkSoft)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(viewType.title)
        .accessibilityLabel(viewType.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.Palette.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(AppTheme.Palette.line, lineWidth: 1)
                )
                .shadow(color: AppTheme.Palette.ink.opacity(0.06), radius: 1, y: 1)
        } else if isHovering {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.45))
        }
    }
}
