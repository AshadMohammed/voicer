import Foundation
import os

#if canImport(FoundationModels)
    import FoundationModels
#endif

struct MeetingSummary: Sendable, Codable, Equatable {
    var title: String
    var keyPoints: [String]
    var actionItems: [String]
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
            Write short bullet notes covering what was discussed, decisions, numbers, names and any tasks
            someone agreed to do. Use only what is in the transcript. Do not add a heading.
            """

        private static let finalInstructions = """
            You write meeting notes from a transcript or from notes on parts of a meeting.
            Each transcript line starts with who is speaking; "You" is the person who recorded the meeting.
            Use only what is in the text. Be brief and concrete.
            """

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

            // Characters per piece, kept well under the model's context so instructions and the answer fit too.
            let limit = max(2_000, Int(Double(model.contextSize) * 1.4))

            do {
                var material = transcript
                var round = 0
                while material.count > limit, round < 4 {
                    round += 1
                    var notes: [String] = []
                    for part in MeetingSummarizer.chunks(of: material, limit: limit) {
                        if let note = try await partNotes(for: part) {
                            notes.append(note)
                        }
                    }
                    guard !notes.isEmpty else {
                        return .skipped(reason: "Apple's on-device model couldn't summarise this meeting.")
                    }
                    material = notes.joined(separator: "\n")
                }

                let draft: MeetingNotesDraft
                do {
                    draft = try await finalDraft(for: material)
                } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                    // The size estimate was too generous for this text (other languages use more tokens per
                    // character): condense once more in smaller pieces and try again.
                    var notes: [String] = []
                    for part in MeetingSummarizer.chunks(of: material, limit: limit / 2) {
                        if let note = try await partNotes(for: part) { notes.append(note) }
                    }
                    draft = try await finalDraft(for: String(notes.joined(separator: "\n").prefix(limit / 2)))
                }
                return .summary(
                    MeetingSummary(
                        title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                        keyPoints: draft.keyPoints.map(clean).filter { !$0.isEmpty },
                        actionItems: draft.actionItems.map(clean).filter { !$0.isEmpty }
                    ))
            } catch {
                logger.error("Meeting summary failed: \(error.localizedDescription, privacy: .public)")
                return .skipped(reason: "Apple's on-device model couldn't summarise this meeting (\(error.localizedDescription)).")
            }
        }

        private static func finalDraft(for material: String) async throws -> MeetingNotesDraft {
            let session = LanguageModelSession(instructions: finalInstructions)
            let response = try await session.respond(
                to: "Write the meeting notes for this:\n\n\(material)",
                generating: MeetingNotesDraft.self
            )
            return response.content
        }

        /// Notes for one part of a long meeting. A part the model refuses is skipped; one that is too
        /// long for the model is halved and tried again.
        private static func partNotes(for part: String, depth: Int = 0) async throws -> String? {
            let session = LanguageModelSession(instructions: partInstructions)
            do {
                return try await session.respond(to: part).content
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize where depth < 3 {
                let halves = MeetingSummarizer.chunks(of: part, limit: max(500, part.count / 2))
                var notes: [String] = []
                for half in halves {
                    if let note = try await partNotes(for: half, depth: depth + 1) { notes.append(note) }
                }
                return notes.isEmpty ? nil : notes.joined(separator: "\n")
            } catch LanguageModelSession.GenerationError.guardrailViolation {
                logger.notice("Skipped a meeting part the on-device model declined to summarise")
                return nil
            }
        }

        private static func clean(_ line: String) -> String {
            line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-•*")))
        }
    }
#endif
