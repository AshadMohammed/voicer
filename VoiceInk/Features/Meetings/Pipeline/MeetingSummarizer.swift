import Foundation
import os

#if canImport(FoundationModels)
    import FoundationModels
#endif

struct MeetingSummary: Sendable, Codable, Equatable {
    var title: String
    var keyPoints: [String]
    var actionItems: [String]
    /// Set when part of a long meeting couldn't be summarised, so the notes may be missing something.
    var note: String? = nil
}

enum MeetingSummaryOutcome: Sendable {
    case summary(MeetingSummary)
    /// The note is saved without a summary; the reason is shown in it.
    case skipped(reason: String)
}

/// Summarises a meeting with Apple's on-device model, so nothing leaves the Mac and it costs nothing.
/// Long meetings don't fit the model's small context, so they are summarised in parts and the
/// part notes are then combined.
enum MeetingSummarizer {
    private static let logger = Logger(subsystem: "com.ashadmohammed.voicer", category: "MeetingSummarizer")

    /// Saved in a note when Apple's model was still downloading; a meeting with this reason is summarised later.
    static let modelNotReadyReason = "Apple's on-device model is still downloading. Summaries will work once it's ready."

    /// True when Apple's on-device model can write a summary right now.
    static var isModelReady: Bool {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                if case .available = SystemLanguageModel.default.availability { return true }
            }
        #endif
        return false
    }

    static func summarize(transcript: String) async -> MeetingSummaryOutcome {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .skipped(reason: "Nothing was said, so there is nothing to summarise.") }

        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                return await OnDeviceMeetingSummarizer.summarize(transcript: trimmed)
            }
        #endif
        return .skipped(reason: "Summaries need macOS 26 or later with Apple Intelligence.")
    }

    /// Splits text into pieces of at most `limit` characters, breaking between lines where possible.
    static func chunks(of text: String, limit: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(line)
            while line.count > limit {
                let head = String(line.prefix(limit))
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                result.append(head)
                line = String(line.dropFirst(limit))
            }
            if current.count + line.count + 1 > limit, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += current.isEmpty ? line : "\n" + line
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Generable
    struct MeetingNotesDraft {
        @Guide(description: "A short, specific title for the meeting, three to eight words")
        var title: String

        @Guide(description: "The main points, decisions and numbers from the meeting, one short sentence each")
        var keyPoints: [String]

        @Guide(
            description:
                "Concrete follow-up tasks, each starting with who will do it when that was said. Empty when there are none."
        )
        var actionItems: [String]
    }

    @available(macOS 26.0, *)
    enum OnDeviceMeetingSummarizer {
        private static let logger = Logger(subsystem: "com.ashadmohammed.voicer", category: "MeetingSummarizer")

        private static let partInstructions = """
            You take notes on part of a meeting transcript. Each line starts with who is speaking.
            Write at most eight short bullet notes, each under twenty words, covering what was discussed,
            decisions, numbers, names and any tasks someone agreed to do. Use only what is in the transcript.
            Write in plain English letters. Do not add a heading.
            """

        private static let combineInstructions = """
            You merge notes taken on consecutive parts of one meeting into a single shorter set of notes.
            Write at most eight short bullet notes, each under twenty words, keeping decisions, numbers, names
            and tasks someone agreed to do. Use only what is in the notes. Write in plain English letters.
            Do not add a heading.
            """

        private static let finalInstructions = """
            You write meeting notes from a transcript or from notes on parts of a meeting.
            Each transcript line starts with who is speaking; "You" is the person who recorded the meeting.
            Use only what is in the text. Be brief and concrete.
            """

        /// The model's window holds the instructions, the text it is given and its own answer. Text for a part
        /// is held to this share of the window, and the answer is capped, so the three can never add up to more.
        private static let partInputShare = 0.5
        private static let finalInputShare = 0.4
        private static let partOutputTokens = 450
        private static let finalOutputTokens = 800
        private static let maxCombineRounds = 6

        static func summarize(transcript: String) async -> MeetingSummaryOutcome {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                break
            case .unavailable(.deviceNotEligible):
                return .skipped(reason: "This Mac can't run Apple's on-device model, so there is no summary.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return .skipped(
                    reason: "Turn on Apple Intelligence in System Settings to get summaries. The transcript is below.")
            case .unavailable(.modelNotReady):
                return .skipped(reason: MeetingSummarizer.modelNotReadyReason)
            case .unavailable:
                return .skipped(reason: "Apple's on-device model isn't available right now, so there is no summary.")
            }

            let window = max(2_048, model.contextSize)
            let partBudget = Int(Double(window) * partInputShare)
            let finalBudget = Int(Double(window) * finalInputShare)
            var skipped = 0
            var attempted = 0
            var lastFailure = ""

            do {
                var material = transcript
                var round = 0
                // Long text is cut into parts that fit the window, each part is turned into short notes, and the
                // notes are cut and condensed again until what is left fits in one final request.
                while await tokenCount(of: material, model: model) > finalBudget, round < maxCombineRounds {
                    round += 1
                    let parts = await fittingChunks(of: material, tokenBudget: partBudget, model: model)
                    var notes: [String] = []
                    for part in parts {
                        try Task.checkCancellation()
                        attempted += 1
                        let instructions = round == 1 ? partInstructions : combineInstructions
                        if let note = try await partNotes(
                            for: part, instructions: instructions, skipped: &skipped, lastFailure: &lastFailure)
                        {
                            notes.append(note)
                        }
                    }
                    guard !notes.isEmpty else {
                        return .skipped(reason: "Apple's on-device model couldn't summarise this meeting (\(lastFailure)).")
                    }
                    let joined = notes.joined(separator: "\n")
                    // Notes that came back no shorter than what they summarise would loop for ever: cut them down.
                    if await tokenCount(of: joined, model: model) >= tokenCount(of: material, model: model) {
                        material = await truncated(joined, toTokens: finalBudget, model: model)
                    } else {
                        material = joined
                    }
                }
                if await tokenCount(of: material, model: model) > finalBudget {
                    material = await truncated(material, toTokens: finalBudget, model: model)
                }

                var draft: MeetingNotesDraft?
                var attempt = 0
                while draft == nil {
                    try Task.checkCancellation()
                    do {
                        draft = try await finalDraft(for: material)
                    } catch let error where isCancellation(error) {
                        throw CancellationError()
                    } catch let error where isContextOverflow(error) && attempt < 4 {
                        attempt += 1
                        material = await truncated(material, toTokens: max(200, finalBudget / (attempt + 1)), model: model)
                    }
                }
                guard let draft else {
                    return .skipped(reason: "Apple's on-device model couldn't summarise this meeting.")
                }

                var note: String?
                if skipped > 0 {
                    note = "Part of this meeting couldn't be summarised (\(skipped) of \(attempted) steps were skipped), so the notes may be missing something."
                }
                return .summary(
                    MeetingSummary(
                        title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                        keyPoints: draft.keyPoints.map(clean).filter { !$0.isEmpty },
                        actionItems: draft.actionItems.map(clean).filter { !$0.isEmpty },
                        note: note
                    ))
            } catch {
                if isCancellation(error) {
                    return .skipped(reason: "The summary was cancelled before it finished.")
                }
                logger.error("Meeting summary failed: \(error.localizedDescription, privacy: .public)")
                return .skipped(reason: "Apple's on-device model couldn't summarise this meeting (\(error.localizedDescription)).")
            }
        }

        // MARK: - Sizing

        /// How many tokens the model counts in `text`. Before macOS 26.4 there is no counter, so the guess is
        /// deliberately high (two characters to a token; English runs near four, other scripts far fewer).
        private static func tokenCount(of text: String, model: SystemLanguageModel) async -> Int {
            if #available(macOS 26.4, *), let count = try? await model.tokenCount(for: text) { return count }
            return text.count / 2 + 1
        }

        /// Cuts `text` into pieces of at most `tokenBudget` tokens, between lines where possible. The size is
        /// estimated from a sample, then each piece is counted for real and halved until it fits.
        private static func fittingChunks(of text: String, tokenBudget: Int, model: SystemLanguageModel) async -> [String] {
            let sample = String(text.prefix(3_000))
            let sampleTokens = max(1, await tokenCount(of: sample, model: model))
            let charsPerToken = min(6, max(1, Double(sample.count) / Double(sampleTokens)))
            let limit = min(20_000, max(400, Int(Double(tokenBudget) * charsPerToken * 0.85)))

            var result: [String] = []
            for chunk in MeetingSummarizer.chunks(of: text, limit: limit) {
                result += await shrunk(chunk, tokenBudget: tokenBudget, model: model)
            }
            return result
        }

        private static func shrunk(_ chunk: String, tokenBudget: Int, model: SystemLanguageModel) async -> [String] {
            if chunk.count <= 200 { return [chunk] }
            if await tokenCount(of: chunk, model: model) <= tokenBudget { return [chunk] }
            var result: [String] = []
            for half in MeetingSummarizer.chunks(of: chunk, limit: max(100, chunk.count / 2)) {
                result += await shrunk(half, tokenBudget: tokenBudget, model: model)
            }
            return result
        }

        /// The start of `text` that fits in `tokens`, cut at a line break when there is one.
        private static func truncated(_ text: String, toTokens tokens: Int, model: SystemLanguageModel) async -> String {
            var result = text
            while await tokenCount(of: result, model: model) > tokens, result.count > 100 {
                var shorter = String(result.prefix(Int(Double(result.count) * 0.8)))
                if let lineBreak = shorter.lastIndex(of: "\n") { shorter = String(shorter[..<lineBreak]) }
                result = shorter.isEmpty ? String(result.prefix(result.count / 2)) : shorter
            }
            return result
        }

        // MARK: - Model calls

        private static func finalDraft(for material: String) async throws -> MeetingNotesDraft {
            let session = LanguageModelSession(instructions: finalInstructions)
            let response = try await session.respond(
                to: "Write the meeting notes for this:\n\n\(material)",
                generating: MeetingNotesDraft.self,
                options: GenerationOptions(maximumResponseTokens: finalOutputTokens)
            )
            return response.content
        }

        /// Notes for one part. A part that is too long for the model is halved and tried again. A part the model
        /// refuses (its safety rules, an unsupported language, a bad answer) is skipped and counted, so one bad
        /// stretch of a long meeting never costs the whole summary.
        private static func partNotes(
            for part: String, instructions: String, depth: Int = 0, skipped: inout Int, lastFailure: inout String
        ) async throws -> String? {
            let session = LanguageModelSession(instructions: instructions)
            do {
                return try await session.respond(
                    to: part, options: GenerationOptions(maximumResponseTokens: partOutputTokens)
                ).content
            } catch let error where isCancellation(error) {
                throw CancellationError()
            } catch let error where isContextOverflow(error) && depth < 4 && part.count > 200 {
                var notes: [String] = []
                for half in MeetingSummarizer.chunks(of: part, limit: max(100, part.count / 2)) {
                    if let note = try await partNotes(
                        for: half, instructions: instructions, depth: depth + 1, skipped: &skipped, lastFailure: &lastFailure)
                    {
                        notes.append(note)
                    }
                }
                return notes.isEmpty ? nil : notes.joined(separator: "\n")
            } catch {
                skipped += 1
                lastFailure = error.localizedDescription
                logger.notice("Skipped a meeting part: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        private static func isCancellation(_ error: Error) -> Bool {
            error is CancellationError || Task.isCancelled
        }

        /// True when the model refused a request for being too big. macOS 27 reports this as a different error
        /// type from macOS 26, so the type is checked first and the wording of the error is the fallback.
        private static func isContextOverflow(_ error: Error) -> Bool {
            if let generation = error as? LanguageModelSession.GenerationError,
                case .exceededContextWindowSize = generation
            {
                return true
            }
            let text = "\(error) \(error.localizedDescription)".lowercased()
            return text.contains("context size") || text.contains("contextsize") || text.contains("context window")
        }

        private static func clean(_ line: String) -> String {
            line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-•*")))
        }
    }
#endif
