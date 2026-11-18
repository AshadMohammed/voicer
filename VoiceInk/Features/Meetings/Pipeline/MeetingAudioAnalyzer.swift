import FluidAudio
import Foundation
import os

/// Turns meeting audio into timed words (Nemotron Multilingual) and speaker turns (FluidAudio's offline diarizer), on this Mac.
/// Keeps its own models so a meeting being processed never fights with live dictation for the same model.
final class MeetingAudioAnalyzer {
    enum AnalyzerError: LocalizedError {
        case speechModelMissing

        var errorDescription: String? {
            switch self {
            case .speechModelMissing:
                return "No Nemotron model is downloaded. Download Nemotron Multilingual in Settings, then try again."
            }
        }
    }

    static let sampleRate: Double = 16_000

    /// The Nemotron model meetings are transcribed with (the same model dictation uses, loaded separately).
    static let speechModelName = "nemotron-multilingual-0.6b"

    private let converter = AudioConverter()
    private var speechTranscriber: MeetingNemotronTranscriber?
    private var diarizer: OfflineDiarizerManager?
    private let logger = Logger(subsystem: "com.ashadmohammed.voicer", category: "MeetingAudioAnalyzer")

    /// True when Nemotron Multilingual is already downloaded.
    static func isSpeechModelDownloaded() -> Bool {
        FluidAudioModelManager.isNemotronModelDownloaded(named: speechModelName)
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
        let transcriber = try loadedSpeechTranscriber()
        let result = try await transcriber.words(in: samples)
        let stats = result.stats
        // Counts and timings only; the transcript itself is never logged.
        logger.notice(
            "Nemotron meeting track: \(stats.pieces) pieces, \(Int(stats.audioSeconds.rounded())) s of audio, \(Int(stats.processingSeconds.rounded())) s to process, \(stats.words) words, \(stats.droppedStockPieces) stock-phrase pieces dropped"
        )
        return result.words
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
        await speechTranscriber?.release()
        speechTranscriber = nil
        diarizer = nil
    }

    private func loadedSpeechTranscriber() throws -> MeetingNemotronTranscriber {
        if let speechTranscriber { return speechTranscriber }
        guard Self.isSpeechModelDownloaded() else {
            throw AnalyzerError.speechModelMissing
        }
        let directory = FluidAudioModelManager.nemotronCacheDirectory(for: Self.speechModelName)
        logger.notice("Loading Nemotron for a meeting from \(directory.path, privacy: .public)")
        let transcriber = MeetingNemotronTranscriber(modelDirectory: directory)
        speechTranscriber = transcriber
        return transcriber
    }
}
