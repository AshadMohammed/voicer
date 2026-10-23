import Foundation
import SwiftUI
import os

/// Runs Voicer's two-model setup: installs SenseVoice Small on a fresh Mac, and swaps between it and
/// Parakeet Ultra from Settings. The model file is only removed once the replacement is downloaded and selected.
@MainActor
final class SpeechModelController: ObservableObject {
    static let shared = SpeechModelController()

    enum SwitchState: Equatable {
        case idle
        case downloading(target: String, fraction: Double, message: String)
        case failed(String)
    }

    @Published private(set) var switchState: SwitchState = .idle
    /// Shown by onboarding and Settings while the first model installs on its own.
    @Published private(set) var autoInstallFraction: Double?
    @Published private(set) var autoInstallFailed = false

    private weak var transcriptionModelManager: TranscriptionModelManager?
    private weak var fluidAudioModelManager: FluidAudioModelManager?
    private let transcribeCppModelManager = TranscribeCppModelManager.shared
    private var switchTask: Task<Void, Never>?
    private var autoInstallTask: Task<Void, Never>?
    private var switchWasCancelled = false

    private let logger = Logger(subsystem: "com.ashadmohammed.voicer", category: "SpeechModelController")

    private init() {}

    func configure(
        transcriptionModelManager: TranscriptionModelManager,
        fluidAudioModelManager: FluidAudioModelManager
    ) {
        self.transcriptionModelManager = transcriptionModelManager
        self.fluidAudioModelManager = fluidAudioModelManager
    }

    // MARK: - Models

    var defaultModel: (any TranscriptionModel)? { offeredModel(named: TranscriptionModelRegistry.defaultModelName) }
    var accurateModel: (any TranscriptionModel)? { offeredModel(named: TranscriptionModelRegistry.accurateModelName) }

    private func offeredModel(named name: String) -> (any TranscriptionModel)? {
        TranscriptionModelRegistry.models.first { $0.name == name }
    }

    /// The model Dictation records with, as long as it is one of the two Voicer offers.
    var activeModel: (any TranscriptionModel)? {
        let mode = ModeManager.shared.getDefaultConfiguration() ?? ModeManager.shared.currentEffectiveConfiguration
        guard let key = mode?.selectedTranscriptionModelName, !key.isEmpty else {
            return nil
        }
        return TranscriptionModelRegistry.model(forSelectionKey: key, in: TranscriptionModelRegistry.models)
    }

    func isDownloaded(_ model: any TranscriptionModel) -> Bool {
        switch model.provider {
        case .fluidAudio:
            return fluidAudioModelManager?.isFluidAudioModelDownloaded(named: model.name) ?? false
        case .transcribeCpp:
            return transcribeCppModelManager.isModelDownloaded(named: model.name)
        default:
            return false
        }
    }

    // MARK: - First launch

    /// Makes sure Dictation exists and points at an installed model. A Mac that already has a working
    /// choice, such as Parakeet Ultra, is left exactly as it is.
    func prepareOnLaunch() {
        guard autoInstallTask == nil, switchTask == nil else { return }
        autoInstallTask = Task { [weak self] in
            await self?.installDefaultIfNeeded()
            self?.autoInstallTask = nil
        }
    }

    /// For the onboarding screen: starts the install again after a failure.
    func retryAutoInstall() {
        autoInstallFailed = false
        prepareOnLaunch()
    }

    private func installDefaultIfNeeded() async {
        guard let defaultModel else { return }

        if UserDefaults.standard.bool(forKey: OnboardingSettings.completedV2Key) {
            ensureDictationMode(model: defaultModel)
        }

        if let current = activeModel, isDownloaded(current) {
            return
        }

        // The mode points at a model that is hidden or missing. Use one that is already on this Mac first.
        let installed = [accurateModel, defaultModel].compactMap { $0 }.first { isDownloaded($0) }
        if let installed {
            select(installed)
            return
        }

        autoInstallFailed = false
        logger.notice("No speech model installed; downloading \(defaultModel.displayName, privacy: .public)")
        let succeeded = await download(defaultModel) { [weak self] fraction in
            self?.autoInstallFraction = fraction
        }
        autoInstallFraction = nil

        if succeeded {
            select(defaultModel)
        } else {
            autoInstallFailed = true
        }
    }

    /// Dictation is the one mode left, so it has to exist even if onboarding never created it.
    private func ensureDictationMode(model: any TranscriptionModel) {
        guard ModeManager.shared.configurations.isEmpty else { return }
        StarterModeFactory.install(
            kinds: [.clean],
            provider: .groq,
            modelName: nil,
            transcriptionModelName: model.selectionKey,
            selectedLanguage: TranscriptionLanguageSupport.validLanguageOrFallback("auto", for: model)
        )
    }

    // MARK: - Switching

    var canSwitch: Bool {
        if case .downloading = switchState { return false }
        return autoInstallTask == nil
    }

    /// Downloads `target`, selects it for Dictation, then deletes the model it replaces.
    func switchTo(_ target: any TranscriptionModel) {
        guard canSwitch, switchTask == nil else { return }
        let previous = activeModel
        switchWasCancelled = false
        switchState = .downloading(target: target.displayName, fraction: 0, message: "")

        switchTask = Task { [weak self] in
            guard let self else { return }
            defer { self.switchTask = nil }

            let succeeded = await self.download(target) { [weak self] fraction in
                self?.switchState = .downloading(target: target.displayName, fraction: fraction, message: "")
            }

            guard succeeded else {
                self.switchState =
                    self.switchWasCancelled
                    ? .idle
                    : .failed(
                        String(
                            format: String(localized: "Couldn't download %@. Your current model is unchanged."),
                            target.displayName))
                return
            }

            self.select(target)

            // Only the model that was replaced is removed, and only now that the new one is in use.
            if let previous, previous.name != target.name, self.activeModel?.name == target.name {
                self.remove(previous)
            }
            self.switchState = .idle
        }
    }

    func cancelSwitch() {
        guard case .downloading = switchState else { return }
        switchWasCancelled = true
        switchTask?.cancel()
    }

    func dismissFailure() {
        if case .failed = switchState { switchState = .idle }
    }

    // MARK: - Plumbing

    /// Starts the download and waits for it. Returns true only when the model is fully installed.
    private func download(
        _ model: any TranscriptionModel,
        progress: @escaping (Double) -> Void
    ) async -> Bool {
        if isDownloaded(model) { return true }

        switch model.provider {
        case .fluidAudio:
            guard let fluidModel = model as? FluidAudioModel, let manager = fluidAudioModelManager else { return false }
            manager.startDownload(fluidModel)
            while manager.isFluidAudioModelDownloading(fluidModel) {
                if Task.isCancelled { manager.cancelDownload(fluidModel) }
                if let status = manager.downloadStatus(for: fluidModel) {
                    progress(status.fractionCompleted)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        case .transcribeCpp:
            guard let cppModel = model as? TranscribeCppModel else { return false }
            transcribeCppModelManager.startDownload(cppModel)
            while transcribeCppModelManager.isModelDownloading(cppModel) {
                if Task.isCancelled { transcribeCppModelManager.cancelDownload(cppModel) }
                if let status = transcribeCppModelManager.downloadStatus(for: cppModel) {
                    progress(status.fractionCompleted)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        default:
            return false
        }

        return isDownloaded(model)
    }

    /// Points Dictation (and the app-wide default) at `model`.
    private func select(_ model: any TranscriptionModel) {
        let language = TranscriptionLanguageSupport.validLanguageOrFallback(
            ModeManager.shared.getDefaultConfiguration()?.selectedLanguage, for: model)

        if var mode = ModeManager.shared.getDefaultConfiguration() {
            mode.selectedTranscriptionModelName = model.selectionKey
            mode.selectedLanguage = language
            ModeManager.shared.updateConfiguration(mode)
            if ModeManager.shared.activeConfiguration?.id == mode.id {
                ModeManager.shared.setActiveConfiguration(mode)
            }
        }
        transcriptionModelManager?.setDefaultTranscriptionModel(model)
    }

    private func remove(_ model: any TranscriptionModel) {
        switch model.provider {
        case .fluidAudio:
            if let fluidModel = model as? FluidAudioModel {
                fluidAudioModelManager?.deleteFluidAudioModel(fluidModel)
            }
        case .transcribeCpp:
            if let cppModel = model as? TranscribeCppModel {
                transcribeCppModelManager.deleteModel(cppModel)
            }
        default:
            break
        }
    }
}
