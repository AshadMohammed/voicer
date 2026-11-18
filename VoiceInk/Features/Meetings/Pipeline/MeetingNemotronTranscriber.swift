import FluidAudio
import Foundation

/// Meeting words from Nemotron Multilingual, on this Mac. A long track is cut into speech pieces with Silero VAD,
/// each piece goes through the same two-decode dictation uses, and every word comes back timed in track time.
/// Owns its own Nemotron manager so a meeting being processed never fights live dictation for the model.
final class MeetingNemotronTranscriber {
    struct Stats: Sendable {
        var pieces = 0
        var audioSeconds: Double = 0
        var processingSeconds: Double = 0
        var droppedStockPieces = 0
        var words = 0
    }

    /// One stretch of the track handed to Nemotron, as sample positions in the whole track.
    struct Piece: Equatable {
        var start: Int
        var end: Int
    }

    static let sampleRate = 16_000
    /// The most audio Nemotron is given at once; with the second of trailing silence it matches dictation's 240,000-sample single chunk.
    static let maxPieceSamples = 14 * sampleRate
    private static let trailingSilence = [Float](repeating: 0, count: sampleRate)
    /// Pieces this close together are decoded as one, so a short pause does not cost a sentence its context.
    private static let mergeGapSamples = sampleRate
    /// A piece quieter than this (RMS) holds no speech worth decoding.
    private static let silentRMS: Float = 0.0005

    private let modelDirectory: URL
    private let lexicon: NemotronMixedSpeechRestorer.Lexicon?
    private var manager: StreamingNemotronMultilingualAsrManager?
    private var vad: VadManager?

    /// `lexicon` is only for callers that run outside the app bundle (the app passes nil).
    init(modelDirectory: URL, lexicon: NemotronMixedSpeechRestorer.Lexicon? = nil) {
        self.modelDirectory = modelDirectory
        self.lexicon = lexicon
    }

    func release() async {
        await manager?.cleanup()
        manager = nil
        vad = nil
    }

    func words(in samples: [Float]) async throws -> (words: [MeetingWord], stats: Stats) {
        var stats = Stats()
        stats.audioSeconds = Double(samples.count) / Double(Self.sampleRate)
        guard !samples.isEmpty else { return ([], stats) }

        let started = Date()
        let manager = try await loadedManager()
        let pieces = Self.pieces(from: await speechRanges(in: samples), samples: samples)
        stats.pieces = pieces.count

        var words: [MeetingWord] = []
        for piece in pieces {
            try Task.checkCancellation()
            let audio = Array(samples[piece.start..<piece.end]) + Self.trailingSilence
            let output = try await NemotronTwoPassDecoder.decode(
                samples: audio, with: manager, languageHint: "auto", lexicon: lexicon)
            let offset = Double(piece.start) / Double(Self.sampleRate)

            // Nemotron writes Hindi in Devanagari; meetings spell it in Roman letters, as dictation does.
            let pieceWords: [MeetingWord] = output.words.compactMap { word in
                let text = HinglishRomanizer.romanize(word.text.trimmingCharacters(in: .whitespacesAndNewlines))
                guard !text.isEmpty else { return nil }
                let start = word.start + offset
                // The last word before a silence is timed as running until the next word, so a word is capped at a
                // second; otherwise pauses vanish and that word drags speaker labels across the gap.
                return MeetingWord(text: text, start: start, end: min(max(word.end + offset, start), start + 1.0))
            }
            // A piece made only of stock phrases ("Thank you for watching") is dropped.
            if TranscriptionOutputFilter.isOnlyStockEchoPhrases(pieceWords.map(\.text).joined(separator: " ")) {
                stats.droppedStockPieces += 1
                continue
            }
            words += pieceWords
        }
        words.sort { $0.start < $1.start }
        stats.words = words.count
        stats.processingSeconds = Date().timeIntervalSince(started)
        return (words, stats)
    }

    // MARK: - Models

    private func loadedManager() async throws -> StreamingNemotronMultilingualAsrManager {
        if let manager { return manager }
        // Nemotron's encoder decodes about 4x faster on the CPU than the Neural Engine on this Mac and loads in 2s, not 20-40s.
        setenv("FLUIDAUDIO_ENCODER_CU", "CPU", 0)
        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: modelDirectory)
        self.manager = manager
        return manager
    }

    /// Speech stretches found by Silero VAD, as sample ranges. Nil when VAD cannot run (the whole track is then
    /// cut into pieces by length, and silent pieces are skipped).
    private func speechRanges(in samples: [Float]) async -> [Range<Int>]? {
        do {
            if vad == nil {
                vad = try await VadManager(config: VadConfig(defaultThreshold: 0.7))
            }
            guard let vad else { return nil }
            // Segments stay under the piece cap even after VAD pads each side by a tenth of a second.
            let segments = try await vad.segmentSpeech(samples, config: VadSegmentationConfig(maxSpeechDuration: 13.5))
            return segments.map { segment in
                let start = max(0, min(segment.startSample(sampleRate: Self.sampleRate), samples.count))
                let end = max(start, min(segment.endSample(sampleRate: Self.sampleRate), samples.count))
                return start..<end
            }
        } catch {
            return nil
        }
    }

    // MARK: - Cutting the track into pieces

    /// Merges close speech ranges, splits any range longer than the cap at its quietest moment, and drops silent pieces.
    static func pieces(from ranges: [Range<Int>]?, samples: [Float]) -> [Piece] {
        var merged: [Range<Int>] = []
        for range in (ranges ?? [0..<samples.count]) where !range.isEmpty {
            if let last = merged.last,
                range.lowerBound - last.upperBound <= mergeGapSamples,
                range.upperBound - last.lowerBound <= maxPieceSamples
            {
                merged[merged.count - 1] = last.lowerBound..<range.upperBound
            } else {
                merged.append(range)
            }
        }

        var pieces: [Piece] = []
        for range in merged {
            var start = range.lowerBound
            while range.upperBound - start > maxPieceSamples {
                let cut = quietestCut(in: samples, from: start, limit: start + maxPieceSamples)
                pieces.append(Piece(start: start, end: cut))
                start = cut
            }
            pieces.append(Piece(start: start, end: range.upperBound))
        }
        return pieces.filter { rms(samples[$0.start..<$0.end]) >= silentRMS }
    }

    /// The quietest 20 ms in the last three seconds before `limit`, so a forced cut lands between words where possible.
    private static func quietestCut(in samples: [Float], from start: Int, limit: Int) -> Int {
        let frame = sampleRate / 50
        let searchStart = max(start + sampleRate, limit - 3 * sampleRate)
        var best = limit
        var bestEnergy = Float.greatestFiniteMagnitude
        var position = searchStart
        while position + frame <= limit {
            let energy = rms(samples[position..<position + frame])
            if energy < bestEnergy {
                bestEnergy = energy
                best = position + frame / 2
            }
            position += frame
        }
        return best
    }

    private static func rms(_ slice: ArraySlice<Float>) -> Float {
        guard !slice.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in slice { sum += sample * sample }
        return (sum / Float(slice.count)).squareRoot()
    }
}
