import SwiftUI

/// One read-only line for the speech model, with a Download button only when its files are missing.
struct SpeechModelSettingsSection: View {
    @ObservedObject private var controller = SpeechModelController.shared
    @EnvironmentObject private var fluidAudioModelManager: FluidAudioModelManager

    var body: some View {
        Section(header: AppSectionLabel("Model")) {
            LabeledContent("Model") {
                Text(summary)
                    .foregroundStyle(.secondary)
            }

            if let model = controller.model, !fluidAudioModelManager.isFluidAudioModelDownloaded(model) {
                if let fraction = controller.autoInstallFraction {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Downloading \(model.displayName)")
                            Spacer()
                            Text(fraction, format: .percent.precision(.fractionLength(0)))
                                .fontDesign(.monospaced)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                    }
                } else {
                    HStack {
                        Text(controller.autoInstallFailed ? "The download failed." : "The model files are missing.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Download") { controller.retryInstall() }
                            .disabled(controller.isInstalling)
                    }
                }
            }
        }
    }

    private var summary: String {
        guard let model = controller.model else { return String(localized: "None") }
        return "\(model.displayName) · \(model.size)"
    }
}
