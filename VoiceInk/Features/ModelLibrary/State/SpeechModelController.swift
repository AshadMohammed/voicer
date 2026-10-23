import Foundation
import SwiftUI
import os

/// Keeps Voicer's one speech model, Parakeet Ultra, installed and selected for Dictation. Nothing here deletes a model.
@MainActor
final class SpeechModelController: ObservableObject {
    static let shared = SpeechModelController()

    /// Shown by onboarding and Settings while the model installs on its own.
    @Published private(set) var autoInstallFraction: Double?
    @Published private(set) var autoInstallFailed = false

    private weak var transcriptionModelManager: TranscriptionModelManager?
    private weak var fluidAudioModelManager: FluidAudioModelManager?
    private var autoInstallTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.ashadmohammed.voicer", category: "SpeechModelController")

    private init() {}

    func configure(
        transcriptionModelManager: TranscriptionModelManager,
        fluidAudioModelManager: FluidAudioModelManager
    ) {
        self.transcriptionModelManager = transcriptionModelManager
        self.fluidAudioModelManager = fluidAudioModelManager
    }

    // MARK: - Model

    var model: FluidAudioModel? {
        TranscriptionModelRegistry.models.compactMap { $0 as? FluidAudioModel }
            .first { $0.name == TranscriptionModelRegistry.defaultModelName }
    }

    var isDownloaded: Bool {
        guard let model else { return false }
        return fluidAudioModelManager?.isFluidAudioModelDownloaded(model) ?? false
    }

    var isInstalling: Bool { autoInstallTask != nil }

    /// The model Dictation records with, as long as it is the one Voicer offers.
    private var activeModel: (any TranscriptionModel)? {
        let mode = ModeManager.shared.getDefaultConfiguration() ?? ModeManager.shared.currentEffectiveConfiguration
        guard let key = mode?.selectedTranscriptionModelName, !key.isEmpty else {
            return nil
        }
        return TranscriptionModelRegistry.model(forSelectionKey: key, in: TranscriptionModelRegistry.models)
    }

    // MARK: - Install

    /// Makes sure Dictation exists and points at an installed model. A Mac that already has Parakeet Ultra
    /// selected is left exactly as it is.
    func prepareOnLaunch() {
        guard autoInstallTask == nil else { return }
        autoInstallFailed = false
        autoInstallTask = Task { [weak self] in
            await self?.installIfNeeded()
            self?.autoInstallTask = nil
        }
    }

    /// For the screens that show a "Try Again" / "Download" button after a failure or a missing file.
    func retryInstall() {
        prepareOnLaunch()
    }

    private func installIfNeeded() async {
        guard let model else { return }

        if UserDefaults.standard.bool(forKey: OnboardingSettings.completedV2Key) {
            ensureDictationMode(model: model)
        }

        if activeModel?.name == model.name, isDownloaded {
            return
        }

        if !isDownloaded {
            logger.notice("Speech model missing; downloading \(model.displayName, privacy: .public)")
            let succeeded = await download(model)
            autoInstallFraction = nil
            guard succeeded else {
                autoInstallFailed = true
                return
            }
        }

        select(model)
    }

    /// Dictation is the one mode left, so it has to exist even if onboarding never created it.
    private func ensureDictationMode(model: FluidAudioModel) {
        guard ModeManager.shared.configurations.isEmpty else { return }
        StarterModeFactory.install(
            kinds: [.clean],
            provider: .groq,
            modelName: nil,
            transcriptionModelName: model.selectionKey,
            selectedLanguage: TranscriptionLanguageSupport.validLanguageOrFallback("auto", for: model)
        )
    }

    /// Starts the download and waits for it. Returns true only when the model is fully installed.
    private func download(_ model: FluidAudioModel) async -> Bool {
        guard let manager = fluidAudioModelManager else { return false }
        if manager.isFluidAudioModelDownloaded(model) { return true }

        manager.startDownload(model)
        while manager.isFluidAudioModelDownloading(model) {
            if let status = manager.downloadStatus(for: model) {
                autoInstallFraction = status.fractionCompleted
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return manager.isFluidAudioModelDownloaded(model)
    }

    /// Points Dictation (and the app-wide default) at `model`.
    private func select(_ model: any TranscriptionModel) {
        if var mode = ModeManager.shared.getDefaultConfiguration() {
            mode.selectedTranscriptionModelName = model.selectionKey
            mode.selectedLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(mode.selectedLanguage, for: model)
            ModeManager.shared.updateConfiguration(mode)
            if ModeManager.shared.activeConfiguration?.id == mode.id {
                ModeManager.shared.setActiveConfiguration(mode)
            }
        }
        transcriptionModelManager?.setDefaultTranscriptionModel(model)
    }
}
