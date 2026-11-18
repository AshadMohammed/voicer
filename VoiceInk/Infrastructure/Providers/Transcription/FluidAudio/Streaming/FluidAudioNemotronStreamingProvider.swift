import FluidAudio
import Foundation
import os

/// True streaming provider backed by FluidAudio's Nemotron multilingual manager.
final class FluidAudioNemotronStreamingProvider: StreamingTranscriptionProvider {
    private let logger = Logger(subsystem: "com.ashadmohammed.voicer", category: "FluidAudioNemotronStreaming")
    private var manager: StreamingNemotronMultilingualAsrManager?
    private var heardSamples: [Float] = []
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init() {
        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    deinit {
        eventsContinuation?.finish()
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        let cacheDirectory = FluidAudioModelManager.nemotronCacheDirectory(for: model.name)
        // Nemotron's encoder decodes about 4x faster on the CPU than the Neural Engine on this Mac and loads in 2s, not 20-40s.
        setenv("FLUIDAUDIO_ENCODER_CU", "CPU", 0)
        let manager = StreamingNemotronMultilingualAsrManager()
        let continuation = eventsContinuation

        await manager.setPartialCallback { partial in
            continuation?.yield(.partial(text: partial))
        }
        try await manager.loadModels(from: cacheDirectory)
        let compatibleLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(
            language,
            for: model
        )
        let languageHint = FluidAudioModelManager.nemotronLanguageHint(from: compatibleLanguage)
        await manager.setLanguage(languageHint)

        self.manager = manager
        eventsContinuation?.yield(.sessionStarted)
        logger.notice("Nemotron streaming started for \(model.displayName, privacy: .public)")
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard let manager else {
            throw StreamingTranscriptionError.notConnected
        }

        let samples = PCMAudioConverter.float32Samples(fromPCM16Data: data)
        guard !samples.isEmpty else { return }

        if heardSamples.count < NemotronLanguageGuard.maxReplaySamples {
            heardSamples.append(contentsOf: samples)
        }
        _ = try await manager.process(samples: samples)
    }

    func commit() async throws {
        guard let manager else {
            throw StreamingTranscriptionError.notConnected
        }

        let trailingSilence = [Float](repeating: 0, count: 16_000)
        _ = try await manager.process(samples: trailingSilence)
        let autoResult = try await manager.finishWithTokenTimings()
        var finalText = autoResult.text
        let needsEnglishPass = NemotronLanguageGuard.needsEnglishPass(finalText)

        if !heardSamples.isEmpty,
           heardSamples.count < NemotronLanguageGuard.maxReplaySamples,
           (needsEnglishPass || NemotronMixedSpeechRestorer.containsDevanagari(finalText)) {
            // Keep the existing whole-clip retry first; mixed text uses the same decode as alignment evidence.
            await manager.setLanguage("en-US")
            await manager.reset()
            _ = try await manager.process(samples: heardSamples + trailingSilence)
            let englishResult = try await manager.finishWithTokenTimings()
            if needsEnglishPass {
                if !englishResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    finalText = englishResult.text
                }
            } else if !englishResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalText = NemotronMixedSpeechRestorer.restore(
                    autoText: finalText,
                    autoWords: timedWords(from: autoResult.timings),
                    englishWords: timedWords(from: englishResult.timings)
                )
            }
        }
        heardSamples.removeAll(keepingCapacity: false)
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        eventsContinuation?.yield(.committed(text: text))
    }

    private func timedWords(from timings: [TokenTiming]) -> [NemotronMixedSpeechRestorer.TimedWord] {
        buildWordTimings(from: timings).map {
            NemotronMixedSpeechRestorer.TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
    }

    func disconnect() async {
        await manager?.cleanup()
        manager = nil
        eventsContinuation?.finish()
        logger.notice("Nemotron streaming disconnected")
    }
}
