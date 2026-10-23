import SwiftUI

/// Voicer installs its own speech model, so this step only shows the download and waits for it. There is no choice to make.
struct OnboardingModelScreen: View {
    let contentMaxWidth: CGFloat
    let model: FluidAudioModel?
    let isDownloaded: Bool
    let isDownloading: Bool
    let downloadStatus: FluidAudioDownloadStatus?
    let didFail: Bool
    let onRetry: () -> Void
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepScreen(
            stage: .model,
            contentMaxWidth: contentMaxWidth
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model?.displayName ?? "Parakeet Ultra")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(AppTheme.Text.primary)

                        Text("Accurate transcription that runs privately on your Mac.")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.Text.secondary)
                    }

                    Spacer()

                    statusLabel
                }

                if let downloadStatus {
                    progressPanel(downloadStatus)
                }
            }
            .padding(18)
            .background(AppMaterialCardBackground(cornerRadius: 12))
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: "Continue",
                isPrimaryEnabled: isDownloaded,
                onLeading: onBack,
                onPrimary: onContinue
            )
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if isDownloaded {
            Text("Ready")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.Text.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(AppTheme.Surface.controlActive))
        } else if didFail && !isDownloading {
            Button("Try Again", action: onRetry)
        } else {
            Text(model?.size ?? "")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.Text.secondary)
        }
    }

    private func progressPanel(_ status: FluidAudioDownloadStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(status.message)
                    .lineLimit(1)

                if status.isIndeterminate {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                }

                Spacer()

                Text(status.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                    .fontDesign(.monospaced)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(AppTheme.Text.secondary)

            ProgressView(value: status.fractionCompleted)
                .progressViewStyle(.linear)
                .tint(AppTheme.Accent.primary)
        }
    }
}
