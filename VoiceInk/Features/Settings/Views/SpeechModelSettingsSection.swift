import SwiftUI

/// The speech model line, with a Download button only when its files are missing, and a picker to switch
/// Dictation between Nemotron and Parakeet Ultra.
struct SpeechModelSettingsSection: View {
    @ObservedObject private var controller = SpeechModelController.shared
    @EnvironmentObject private var fluidAudioModelManager: FluidAudioModelManager

    @State private var selectedKey = ""

    /// Nemotron and Parakeet Ultra, the ones Settings can switch between.
    private var pickableModels: [any TranscriptionModel] {
        TranscriptionModelRegistry.models.filter {
            $0.name == TranscriptionModelRegistry.defaultModelName
                || $0.name == TranscriptionModelRegistry.dictationParakeetName
        }
    }

    var body: some View {
        Section(header: AppSectionLabel("Model")) {
            LabeledContent("Model") {
                Text(summary)
                    .foregroundStyle(.secondary)
            }

            Picker("Dictation model", selection: $selectedKey) {
                ForEach(pickableModels, id: \.selectionKey) { model in
                    Text(model.displayName).tag(model.selectionKey)
                }
            }
            .onAppear { selectedKey = controller.activeModelKey ?? TranscriptionModelRegistry.defaultModelName }
            .onChange(of: selectedKey) { _, key in choose(key) }

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

    private func choose(_ key: String) {
        guard key != controller.activeModelKey,
            let model = pickableModels.first(where: { $0.selectionKey == key })
        else { return }
        controller.select(model)
    }
}
