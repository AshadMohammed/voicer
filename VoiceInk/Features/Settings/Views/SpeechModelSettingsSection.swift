import SwiftUI

/// Settings section for the speech model: which one is active, and a one-tap swap to the other.
struct SpeechModelSettingsSection: View {
    @ObservedObject private var controller = SpeechModelController.shared
    @ObservedObject private var modeManager = ModeManager.shared
    @ObservedObject private var cppModelManager = TranscribeCppModelManager.shared
    @EnvironmentObject private var fluidAudioModelManager: FluidAudioModelManager

    var body: some View {
        Section(header: AppSectionLabel("Speech model")) {
            LabeledContent("Active model") {
                Text(activeModelSummary)
                    .foregroundStyle(.secondary)
            }

            if let model = controller.activeModel {
                if model.name == TranscriptionModelRegistry.defaultModelName {
                    switchRow(
                        message:
                            "Having accuracy issues? Switch to Parakeet Ultra — slightly more accurate, same speed, uses about 400 MB more space.",
                        buttonTitle: "Switch to Parakeet Ultra",
                        target: controller.accurateModel
                    )
                } else {
                    switchRow(
                        message: "Switch back to the smaller model (frees about 400 MB).",
                        buttonTitle: "Switch to SenseVoice Small",
                        target: controller.defaultModel
                    )
                }
            } else if let fraction = controller.autoInstallFraction {
                progressRow(title: "Downloading SenseVoice Small", fraction: fraction)
            } else if controller.autoInstallFailed {
                HStack {
                    Text("SenseVoice Small couldn't be downloaded.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Try Again") { controller.retryAutoInstall() }
                }
            } else {
                Text("Voicer is setting up its speech model.")
                    .foregroundStyle(.secondary)
            }

            switch controller.switchState {
            case .idle:
                EmptyView()
            case .downloading(let target, let fraction, _):
                progressRow(title: "Downloading \(target)", fraction: fraction)
            case .failed(let message):
                HStack {
                    Text(message)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { controller.dismissFailure() }
                }
            }
        }
    }

    private var activeModelSummary: String {
        guard let model = controller.activeModel else {
            return String(localized: "None")
        }
        return "\(model.displayName) · \(Self.size(of: model))"
    }

    @ViewBuilder
    private func switchRow(message: LocalizedStringKey, buttonTitle: LocalizedStringKey, target: (any TranscriptionModel)?)
        -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let target {
                HStack {
                    Button(buttonTitle) { controller.switchTo(target) }
                        .disabled(!controller.canSwitch)
                    if case .downloading = controller.switchState {
                        Button("Cancel") { controller.cancelSwitch() }
                    }
                }
            }
        }
    }

    private func progressRow(title: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .fontDesign(.monospaced)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
        }
    }

    private static func size(of model: any TranscriptionModel) -> String {
        if let model = model as? FluidAudioModel { return model.size }
        if let model = model as? TranscribeCppModel { return model.size }
        return ""
    }
}
