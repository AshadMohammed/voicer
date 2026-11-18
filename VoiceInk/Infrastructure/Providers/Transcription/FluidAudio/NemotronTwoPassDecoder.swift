import FluidAudio
import Foundation

/// Nemotron's two-decode: one pass on auto-language, then an en-US pass when the first one wrote English as Hindi
/// (or mixed Hindi and English), merged by the mixed-speech restorer. Dictation and meetings both call this, so
/// the decision lives in one place.
enum NemotronTwoPassDecoder {
    struct Output: Sendable {
        /// What dictation uses: the model's own text, or the restorer's merge.
        let text: String
        /// The same words with times, in seconds from the start of the audio that was fed in.
        let words: [NemotronMixedSpeechRestorer.TimedWord]
    }

    /// Decodes `samples` (16 kHz mono, already padded with any trailing silence the caller wants) and leaves the
    /// manager reset-ready for the next call. `lexicon` is for callers outside the app bundle; the app passes nil.
    static func decode(
        samples: [Float],
        with manager: StreamingNemotronMultilingualAsrManager,
        languageHint: String,
        lexicon: NemotronMixedSpeechRestorer.Lexicon? = nil
    ) async throws -> Output {
        await manager.setLanguage(languageHint)
        await manager.reset()
        _ = try await manager.process(samples: samples)
        let autoResult = try await manager.finishWithTokenTimings()
        let text = autoResult.text
        let autoWords = timedWords(from: autoResult.timings)

        let needsEnglishPass = NemotronLanguageGuard.needsEnglishPass(text)
        guard needsEnglishPass || NemotronMixedSpeechRestorer.containsDevanagari(text) else {
            return Output(text: text, words: autoWords)
        }

        // Keep the existing whole-clip retry first; mixed text uses it as alignment evidence.
        await manager.setLanguage("en-US")
        await manager.reset()
        _ = try await manager.process(samples: samples)
        let englishResult = try await manager.finishWithTokenTimings()
        guard !englishResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Output(text: text, words: autoWords)
        }
        let englishWords = timedWords(from: englishResult.timings)
        if needsEnglishPass {
            return Output(text: englishResult.text, words: englishWords)
        }

        let restored = NemotronMixedSpeechRestorer.restore(
            autoText: text,
            autoWords: autoWords,
            englishWords: englishWords,
            lexicon: lexicon
        )
        return Output(
            text: restored,
            words: timedWords(for: restored, autoWords: autoWords, englishWords: englishWords)
        )
    }

    /// The restorer returns text only. Its words take the times of the decode they came from when the counts match;
    /// otherwise they are spread evenly between the first and last timed word of the piece.
    static func timedWords(
        for text: String,
        autoWords: [NemotronMixedSpeechRestorer.TimedWord],
        englishWords: [NemotronMixedSpeechRestorer.TimedWord]
    ) -> [NemotronMixedSpeechRestorer.TimedWord] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        for source in [autoWords, englishWords] where source.count == tokens.count {
            return zip(tokens, source).map {
                NemotronMixedSpeechRestorer.TimedWord(text: $0, start: $1.start, end: $1.end)
            }
        }
        let timed = autoWords.isEmpty ? englishWords : autoWords
        guard let first = timed.first, let last = timed.last else { return [] }
        let start = first.start
        let span = max(last.end - start, 0)
        let step = span / Double(tokens.count)
        return tokens.enumerated().map { index, token in
            NemotronMixedSpeechRestorer.TimedWord(
                text: token,
                start: start + step * Double(index),
                end: start + step * Double(index + 1)
            )
        }
    }

    static func timedWords(from timings: [TokenTiming]) -> [NemotronMixedSpeechRestorer.TimedWord] {
        buildWordTimings(from: timings).map {
            NemotronMixedSpeechRestorer.TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
    }
}
