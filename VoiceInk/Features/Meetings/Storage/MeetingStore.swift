import Foundation

/// Thread-safe store for meeting records and Markdown notes.
///
/// Layout:
/// - Notes  → `~/Documents/Voicer Meetings/<yyyy-MM-dd HHmm> <title>.md`
/// - Mixed audio → same folder and name as the note, `.m4a` (when "Save meeting audio to Documents" is on)
/// - Data   → `~/Library/Application Support/com.ashadmohammed.Voicer/Meetings/<uuid>/meeting.json`
/// - Audio  → same `<uuid>` folder (written by the lead's recorder)
final class MeetingStore: @unchecked Sendable {
    static let shared = MeetingStore()

    struct InterruptedRecording: Sendable {
        let id: UUID
        let folder: URL
        let startedAt: Date
        let microphoneURL: URL?
        let callURL: URL?
    }

    static let didChangeNotification = Notification.Name("MeetingStoreDidChange")

    // MARK: - Defaults

    /// "Save meeting audio to Documents" on the Meetings page. On unless the user turned it off.
    static let saveAudioToDocumentsKey = "saveMeetingAudioToDocuments"

    static var saveAudioToDocuments: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: saveAudioToDocumentsKey) == nil ? true : defaults.bool(forKey: saveAudioToDocumentsKey)
    }

    static var defaultNotesFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voicer Meetings", isDirectory: true)
    }

    static var defaultDataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.ashadmohammed.Voicer/Meetings", isDirectory: true)
    }

    // MARK: - Properties

    let notesFolder: URL
    let dataFolder: URL

    /// Serialises all file I/O so callers can safely use this from background tasks.
    private let queue = DispatchQueue(label: "com.ashadmohammed.voicer.meeting-store")

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Init

    init(
        notesFolder: URL = MeetingStore.defaultNotesFolder,
        dataFolder: URL = MeetingStore.defaultDataFolder
    ) {
        self.notesFolder = notesFolder
        self.dataFolder  = dataFolder
    }

    // MARK: - Public API

    /// The per-meeting folder for audio and JSON, created on demand.
    func meetingFolder(for id: UUID) throws -> URL {
        let url = dataFolder.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Saves the Markdown note and JSON record. Picks a unique note file name on first save.
    /// - Returns: URL of the written Markdown note.
    @discardableResult
    func save(_ record: inout MeetingRecord) throws -> URL {
        // Capture mutable copy for the closure; we'll copy the result back.
        var localRecord = record
        var resultURL: URL?
        var resultError: Error?

        queue.sync {
            do {
                resultURL = try self.writeToDisk(&localRecord)
            } catch {
                resultError = error
            }
        }

        if let error = resultError { throw error }
        record = localRecord

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: MeetingStore.didChangeNotification, object: self)
        }
        return resultURL!
    }

    /// All saved meetings, newest first. Skips unreadable JSON silently.
    func loadAll() -> [MeetingRecord] {
        var records: [MeetingRecord] = []
        queue.sync {
            records = self.readAllFromDisk()
        }
        return records
    }

    /// Raw tracks without a saved record are interrupted recordings. Failed folders are retried at most three launches.
    func interruptedRecordings(excluding activeID: UUID? = nil) -> [InterruptedRecording] {
        var candidates: [InterruptedRecording] = []
        queue.sync {
            let fm = FileManager.default
            guard let folders = try? fm.contentsOfDirectory(
                at: dataFolder, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { return }

            for folder in folders {
                guard let id = UUID(uuidString: folder.lastPathComponent), id != activeID else { continue }
                guard !fm.fileExists(atPath: folder.appendingPathComponent("meeting.json").path) else { continue }
                let marker = folder.appendingPathComponent("recovery-attempts")
                let attemptsText = try? String(contentsOf: marker, encoding: .utf8)
                let attempts = attemptsText.flatMap { Int($0) } ?? 0
                guard attempts < 3 else { continue }

                let microphone = folder.appendingPathComponent("microphone.caf")
                let call = folder.appendingPathComponent("call.caf")
                let microphoneURL = hasAudioData(microphone) ? microphone : nil
                let callURL = hasAudioData(call) ? call : nil
                guard microphoneURL != nil || callURL != nil else { continue }

                let folderValues = try? folder.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let trackDate = [microphoneURL, callURL].compactMap { url -> Date? in
                    guard let url else { return nil }
                    return try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
                }.min()
                let startedAt = folderValues?.creationDate ?? trackDate
                    ?? folderValues?.contentModificationDate ?? Date()
                candidates.append(InterruptedRecording(
                    id: id, folder: folder, startedAt: startedAt,
                    microphoneURL: microphoneURL, callURL: callURL))
            }
        }
        return candidates.sorted { $0.startedAt < $1.startedAt }
    }

    /// Records an attempt before work begins so crashes cannot retry the same broken folder forever.
    func beginRecoveryAttempt(for recording: InterruptedRecording) -> Int? {
        var attempt: Int?
        queue.sync {
            let marker = recording.folder.appendingPathComponent("recovery-attempts")
            let previousText = try? String(contentsOf: marker, encoding: .utf8)
            let previous = previousText.flatMap { Int($0) } ?? 0
            guard previous < 3 else { return }
            let next = previous + 1
            do {
                try String(next).write(to: marker, atomically: true, encoding: .utf8)
                attempt = next
            } catch {
                attempt = nil
            }
        }
        return attempt
    }

    func finishRecovery(for recording: InterruptedRecording) {
        queue.sync {
            try? FileManager.default.removeItem(at: recording.folder.appendingPathComponent("recovery-attempts"))
        }
    }

    /// URL of the Markdown note for a record. The file may not exist yet.
    func noteURL(for record: MeetingRecord) -> URL {
        notesFolder.appendingPathComponent(record.noteFileName)
    }

    /// URL of the mixed audio kept beside the note, if one was saved.
    func savedAudioURL(for record: MeetingRecord) -> URL? {
        guard let name = record.savedAudioFileName, !name.isEmpty else { return nil }
        return notesFolder.appendingPathComponent(name)
    }

    /// Moves a finished mix into the notes folder as `<note name>.m4a`. Needs the note to have been saved first,
    /// so the two share a name. Returns the new file name.
    func adoptSavedAudio(from tempURL: URL, for record: MeetingRecord) throws -> String {
        var result = ""
        var moveError: Error?
        queue.sync {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: self.notesFolder, withIntermediateDirectories: true)
                let base = (record.noteFileName as NSString).deletingPathExtension
                let name = "\(base).m4a"
                let destination = self.notesFolder.appendingPathComponent(name)
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.moveItem(at: tempURL, to: destination)
                result = name
            } catch {
                moveError = error
            }
        }
        if let moveError { throw moveError }
        return result
    }

    /// Moves the Markdown note and the saved audio to the Trash and deletes the meeting's data folder.
    func delete(_ record: MeetingRecord) throws {
        var deleteError: Error?
        queue.sync {
            do {
                // Trash the note if it has been saved.
                if !record.noteFileName.isEmpty {
                    let note = self.notesFolder.appendingPathComponent(record.noteFileName)
                    if FileManager.default.fileExists(atPath: note.path) {
                        try FileManager.default.trashItem(at: note, resultingItemURL: nil)
                    }
                }
                // Trash the mixed audio kept beside the note.
                if let audio = self.savedAudioURL(for: record), FileManager.default.fileExists(atPath: audio.path) {
                    try FileManager.default.trashItem(at: audio, resultingItemURL: nil)
                }
                // Remove the data folder entirely.
                let folder = self.dataFolder.appendingPathComponent(record.id.uuidString)
                if FileManager.default.fileExists(atPath: folder.path) {
                    try FileManager.default.removeItem(at: folder)
                }
            } catch {
                deleteError = error
            }
        }
        if let error = deleteError { throw error }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: MeetingStore.didChangeNotification, object: self)
        }
    }

    // MARK: - Private helpers (call only on `queue`)

    private func writeToDisk(_ record: inout MeetingRecord) throws -> URL {
        // Ensure folders exist.
        let fm = FileManager.default
        try fm.createDirectory(at: notesFolder, withIntermediateDirectories: true)
        let meetingDir = dataFolder.appendingPathComponent(record.id.uuidString, isDirectory: true)
        try fm.createDirectory(at: meetingDir, withIntermediateDirectories: true)

        // Pick a note file name on first save.
        if record.noteFileName.isEmpty {
            record.noteFileName = uniqueNoteFileName(for: record)
        }

        // Write Markdown note (atomic).
        let markdown = MeetingMarkdown.render(record)
        let noteURL = notesFolder.appendingPathComponent(record.noteFileName)
        try writeAtomic(data: Data(markdown.utf8), to: noteURL)

        // Write JSON record (atomic).
        let jsonData = try encoder.encode(record)
        let jsonURL = meetingDir.appendingPathComponent("meeting.json")
        try writeAtomic(data: jsonData, to: jsonURL)
        return noteURL
    }

    private func readAllFromDisk() -> [MeetingRecord] {
        let fm = FileManager.default
        guard let uuidDirs = try? fm.contentsOfDirectory(
            at: dataFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        var records: [MeetingRecord] = []
        for dir in uuidDirs {
            let jsonURL = dir.appendingPathComponent("meeting.json")
            guard
                let data = try? Data(contentsOf: jsonURL),
                let record = try? decoder.decode(MeetingRecord.self, from: data)
            else { continue }
            records.append(record)
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    private func hasAudioData(_ url: URL) -> Bool {
        CAFRecoveryReader.containsAudioData(of: url)
    }

    /// Returns a filesystem-safe, unique note file name for `record`.
    private func uniqueNoteFileName(for record: MeetingRecord) -> String {
        let dateStr = noteFileDateString(from: record.startedAt)
        let sanitised = sanitiseTitle(record.displayTitle)
        let base = "\(dateStr) \(sanitised)"
        let candidate = "\(base).md"

        if !noteFileExists(candidate) { return candidate }
        for n in 2...99 {
            let numbered = "\(base) \(n).md"
            if !noteFileExists(numbered) { return numbered }
        }
        // Last resort: append UUID fragment.
        return "\(base) \(record.id.uuidString.prefix(8)).md"
    }

    private func noteFileDateString(from date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HHmm"
        return fmt.string(from: date)
    }

    /// Strips characters that are unsafe in macOS file names, caps title at ~60 chars.
    private func sanitiseTitle(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\*?\"<>|").union(.controlCharacters).union(.newlines)
        let safe = title.unicodeScalars
            .filter { !forbidden.contains($0) }
            .map { Character($0) }
        let cleaned = String(safe)
            .trimmingCharacters(in: .whitespaces)
        guard cleaned.count > 60 else { return cleaned.isEmpty ? "Meeting" : cleaned }
        // Break at a word boundary near 60 chars.
        let prefix = String(cleaned.prefix(60))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace])
        }
        return prefix
    }

    private func noteFileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: notesFolder.appendingPathComponent(name).path
        )
    }

    /// `.atomic` writes to a temporary file and swaps it in, so a crash never leaves half a note.
    private func writeAtomic(data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

