import FluidAudio
import Foundation
import os

/// Turns meeting audio into timed words (Parakeet) and speaker turns (FluidAudio's offline diarizer), on this Mac.
/// Keeps its own models so a meeting being processed never fights with live dictation for the same model.
final class MeetingAudioAnalyzer {
    enum AnalyzerError: LocalizedError {
        case speechModelMissing

        var errorDescription: String? {
            switch self {
            case .speechModelMissing:
                return "No Parakeet model is downloaded. Download Parakeet Ultra in Settings, then try again."
            }
        }
    }

    static let sampleRate: Double = 16_000

    private let asrVersion: AsrModelVersion
    private let converter = AudioConverter()
    private var asrManager: AsrManager?
    private var diarizer: OfflineDiarizerManager?
    private let logger = Logger(subsystem: "com.ashadmohammed.voicer", category: "MeetingAudioAnalyzer")

    init(asrVersion: AsrModelVersion) {
        self.asrVersion = asrVersion
    }

    /// The Parakeet versions that give word timings, best first, that are already downloaded.
    static func downloadedSpeechModels() -> [AsrModelVersion] {
        [.ultra, .v3, .v2].filter {
            AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: $0), version: $0)
        }
    }

    /// Any audio or video file, as 16 kHz mono samples.
    func samples(from url: URL) throws -> [Float] {
        let repairedURL = try CAFRecoveryReader.repairedCopyIfNeeded(of: url)
        defer {
            if let repairedURL { try? FileManager.default.removeItem(at: repairedURL) }
        }
        return try converter.resampleAudioFile(repairedURL ?? url)
    }

    /// True when a track never rises above a whisper, for example the call audio of an in-person meeting
    /// or a call track recorded without the system audio permission.
    static func isSilent(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        var peak: Float = 0
        var sumSquares: Double = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            sumSquares += Double(sample * sample)
        }
        let rms = (sumSquares / Double(samples.count)).squareRoot()
        return peak < 0.01 || rms < 0.0005
    }

    func words(in samples: [Float]) async throws -> [MeetingWord] {
        guard !samples.isEmpty else { return [] }
        let manager = try await loadedSpeechModel()
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoderState, language: nil)

        guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let duration = Double(samples.count) / Self.sampleRate
            return text.isEmpty ? [] : [MeetingWord(text: text, start: 0, end: duration)]
        }

        // The last word before a silence is timed as running until the next word, so a word is capped
        // at a second; otherwise pauses vanish and that word drags speaker labels across the gap.
        return buildWordTimings(from: tokenTimings).map {
            MeetingWord(text: $0.word, start: $0.startTime, end: min($0.endTime, $0.startTime + 1.0))
        }
    }

    /// Who spoke when. The diarizer's models download once (a few tens of MB) the first time it runs.
    func speakerSpans(in samples: [Float]) async throws -> [MeetingSpeakerSpan] {
        guard !samples.isEmpty else { return [] }
        let manager: OfflineDiarizerManager
        if let diarizer {
            manager = diarizer
        } else {
            manager = OfflineDiarizerManager(config: .default)
            try await manager.prepareModels()
            diarizer = manager
        }
        let result = try await manager.process(audio: samples)
        return result.segments.map {
            MeetingSpeakerSpan(
                speakerID: $0.speakerId,
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds)
            )
        }
    }

    func release() async {
        await asrManager?.cleanup()
        asrManager = nil
        diarizer = nil
    }

    private func loadedSpeechModel() async throws -> AsrManager {
        if let asrManager { return asrManager }
        let directory = AsrModels.defaultCacheDirectory(for: asrVersion)
        guard AsrModels.modelsExist(at: directory, version: asrVersion) else {
            throw AnalyzerError.speechModelMissing
        }
        logger.notice("Loading Parakeet for a meeting from \(directory.path, privacy: .public)")
        let models = try await AsrModels.load(
            from: directory,
            configuration: nil,
            version: asrVersion,
            encoderPrecision: .int8
        )
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asrManager = manager
        return manager
    }
}
