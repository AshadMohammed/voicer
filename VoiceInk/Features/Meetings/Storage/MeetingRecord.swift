import Foundation

/// One saved meeting. Stored as JSON next to its audio; the Markdown note is the user-facing copy.
struct MeetingRecord: Codable, Identifiable, Sendable, Equatable {
    enum Source: String, Codable, Sendable { case recorded, imported }

    var id: UUID
    var title: String
    var startedAt: Date
    var duration: TimeInterval
    var source: Source
    var importedFileName: String?
    var summary: MeetingSummary?
    var summaryUnavailableReason: String?
    var utterances: [MeetingUtterance]
    var notes: [String]
    var audioFileNames: [String]
    /// The `.md` file name inside the notes folder. Empty string until first save.
    var noteFileName: String

    // MARK: - Derived

    /// Plain transcript, one "Speaker: text" line per utterance.
    var transcriptText: String {
        utterances.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    /// `title` when non-empty; otherwise a dated fallback like "Meeting, 20 Oct 16:30".
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty else { return trimmed }
        let fmt = DateFormatter()
        fmt.dateFormat = "d MMM HH:mm"
        return "Meeting, \(fmt.string(from: startedAt))"
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        duration: TimeInterval,
        source: Source,
        importedFileName: String? = nil,
        summary: MeetingSummary? = nil,
        summaryUnavailableReason: String? = nil,
        utterances: [MeetingUtterance] = [],
        notes: [String] = [],
        audioFileNames: [String] = [],
        noteFileName: String = ""
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.source = source
        self.importedFileName = importedFileName
        self.summary = summary
        self.summaryUnavailableReason = summaryUnavailableReason
        self.utterances = utterances
        self.notes = notes
        self.audioFileNames = audioFileNames
        self.noteFileName = noteFileName
    }

    // MARK: - Codable (tolerates missing optional fields from older JSON)

    enum CodingKeys: String, CodingKey {
        case id, title, startedAt, duration, source
        case importedFileName, summary, summaryUnavailableReason
        case utterances, notes, audioFileNames, noteFileName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                      = try c.decode(UUID.self,              forKey: .id)
        title                   = try c.decode(String.self,            forKey: .title)
        startedAt               = try c.decode(Date.self,              forKey: .startedAt)
        duration                = try c.decode(TimeInterval.self,      forKey: .duration)
        source                  = try c.decodeIfPresent(Source.self,   forKey: .source) ?? .recorded
        importedFileName        = try c.decodeIfPresent(String.self,   forKey: .importedFileName)
        summary                 = try c.decodeIfPresent(MeetingSummary.self, forKey: .summary)
        summaryUnavailableReason = try c.decodeIfPresent(String.self,  forKey: .summaryUnavailableReason)
        utterances              = try c.decodeIfPresent([MeetingUtterance].self, forKey: .utterances) ?? []
        notes                   = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        audioFileNames          = try c.decodeIfPresent([String].self, forKey: .audioFileNames) ?? []
        noteFileName            = try c.decodeIfPresent(String.self,   forKey: .noteFileName) ?? ""
    }
}

