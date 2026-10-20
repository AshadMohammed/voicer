import FluidAudio
import Foundation
import os

/// The audio of one meeting: your microphone and the call's sound as separate tracks (either can be missing
/// when it couldn't be recorded), or a single recording brought in from a file.
enum MeetingAudio: Sendable {
    case tracks(microphone: URL?, call: URL?)
    case singleRecording(URL)
}

struct MeetingResult: Sendable {
    var utterances: [MeetingUtterance]
    var summary: MeetingSummaryOutcome
    var duration: TimeInterval
    /// Things worth telling the reader of the note, such as a silent call track.
    var notes: [String]
}

/// Runs a finished meeting through transcription, speaker labelling and the summary.
enum MeetingProcessor {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingProcessor")

    static func process(
        _ audio: MeetingAudio,
        asrVersion: AsrModelVersion,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> MeetingResult {
        let analyzer = MeetingAudioAnalyzer(asrVersion: asrVersion)
        let transcript: Transcript
        do {
            transcript = try await transcribe(audio, analyzer: analyzer, progress: progress)
        } catch {
            await analyzer.release()
            throw error
        }
        // The speech models are let go before Apple's model loads for the summary; long meetings need the memory.
        await analyzer.release()

        progress("Writing the summary")
        let summary = await MeetingSummarizer.summarize(transcript: MeetingTranscriptAssembler.plainText(transcript.utterances))
        return MeetingResult(
            utterances: transcript.utterances, summary: summary, duration: transcript.duration, notes: transcript.notes)
    }

    private struct Transcript {
        var utterances: [MeetingUtterance]
        var duration: TimeInterval
        var notes: [String]
    }

    private static func transcribe(
        _ audio: MeetingAudio,
        analyzer: MeetingAudioAnalyzer,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> Transcript {
        var notes: [String] = []
        var groups: [[MeetingUtterance]] = []
        var duration: TimeInterval = 0

        switch audio {
        case .tracks(let microphoneURL, let callURL):
            progress("Reading the recording")
            let micSamples = try microphoneURL.map { try analyzer.samples(from: $0) } ?? []
            let callSamples = try callURL.map { try analyzer.samples(from: $0) } ?? []
            duration = Double(max(micSamples.count, callSamples.count)) / MeetingAudioAnalyzer.sampleRate
            if microphoneURL == nil {
                notes.append("Your microphone wasn't recorded, so only the call's audio is transcribed.")
            }

            if MeetingAudioAnalyzer.isSilent(callSamples) {
                // Nothing came through the call audio: an in-person meeting, or system audio wasn't allowed.
                if callURL != nil {
                    notes.append(
                        "No call audio was recorded, so everyone is labelled from your microphone. If this was a call, check that Voicer is allowed under System Settings > Privacy & Security > Screen & System Audio Recording."
                    )
                }
                groups.append(try await labelledByVoice(micSamples, analyzer: analyzer, firstNumber: 1, progress: progress))
            } else if MeetingAudioAnalyzer.isSilent(micSamples) {
                // A muted or missing microphone: everyone who spoke is on the call track.
                groups.append(try await labelledByVoice(callSamples, analyzer: analyzer, firstNumber: 1, progress: progress))
            } else {
                progress("Writing out what you said")
                let ownWords = try await analyzer.words(in: micSamples)
                progress("Writing out the call")
                let callWords = try await analyzer.words(in: callSamples)
                progress("Working out who said what")
                let spans = try await diarizedSpans(callSamples, analyzer: analyzer, notes: &notes)

                // With speakers instead of headphones the mic also hears the call; those words are dropped.
                let ownSpoken = MeetingTranscriptAssembler.removingEcho(from: ownWords, heardIn: callWords)
                if ownWords.count > ownSpoken.count {
                    logger.notice("Dropped \(ownWords.count - ownSpoken.count) echoed words from the microphone track")
                }
                let own = MeetingTranscriptAssembler.droppingEchoScraps(
                    MeetingTranscriptAssembler.utterances(
                        from: ownSpoken, speaker: MeetingTranscriptAssembler.ownSpeakerName),
                    callWords: callWords
                )
                // "Speaker 2" onwards only reads right when "You" are in the transcript as the first voice.
                let names = MeetingTranscriptAssembler.speakerNames(for: spans, firstNumber: own.isEmpty ? 1 : 2)
                groups.append(own)
                groups.append(MeetingTranscriptAssembler.utterances(from: callWords, spans: spans, names: names))
            }

        case .singleRecording(let url):
            progress("Reading the recording")
            let samples = try analyzer.samples(from: url)
            duration = Double(samples.count) / MeetingAudioAnalyzer.sampleRate
            groups.append(try await labelledByVoice(samples, analyzer: analyzer, firstNumber: 1, progress: progress))
        }

        return Transcript(utterances: MeetingTranscriptAssembler.merged(groups), duration: duration, notes: notes)
    }

    /// One track with several people on it: transcribe, then split it by voice.
    private static func labelledByVoice(
        _ samples: [Float],
        analyzer: MeetingAudioAnalyzer,
        firstNumber: Int,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> [MeetingUtterance] {
        progress("Writing out the recording")
        let words = try await analyzer.words(in: samples)
        progress("Working out who said what")
        var ignored: [String] = []
        let spans = try await diarizedSpans(samples, analyzer: analyzer, notes: &ignored)
        let names = MeetingTranscriptAssembler.speakerNames(for: spans, firstNumber: firstNumber)
        return MeetingTranscriptAssembler.utterances(from: words, spans: spans, names: names)
    }

    /// Speaker turns, or none when the diarizer can't run (for example offline before its models
    /// have downloaded); the transcript then keeps everyone under one label instead of failing.
    private static func diarizedSpans(
        _ samples: [Float],
        analyzer: MeetingAudioAnalyzer,
        notes: inout [String]
    ) async throws -> [MeetingSpeakerSpan] {
        do {
            return try await analyzer.speakerSpans(in: samples)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Speaker labelling failed: \(error.localizedDescription, privacy: .public)")
            notes.append("Voicer couldn't tell the speakers apart this time (\(error.localizedDescription)).")
            return []
        }
    }
}
