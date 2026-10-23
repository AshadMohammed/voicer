import AVFoundation
import AppKit
import FluidAudio
import Foundation
import SwiftData
import os

/// Runs the meeting recorder: starting and stopping a recording, importing a file, processing one meeting at a
/// time (transcript, speakers, summary), and saving the note plus a History entry.
@MainActor
final class MeetingsCoordinator: ObservableObject {
    static let shared = MeetingsCoordinator()

    enum RecordingState: Equatable {
        case idle
        case starting
        case recording(id: UUID, startedAt: Date)
        case finishing
    }

    /// A meeting waiting for, or going through, transcription and the summary.
    struct Job: Identifiable, Equatable {
        let id: UUID
        var title: String
        var stage: String
    }

    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var meetings: [MeetingRecord] = []
    /// Meetings whose summary is being written right now, or is waiting its turn.
    @Published private(set) var summarisingIDs = Set<UUID>()

    var isRecording: Bool {
        if case .recording = recordingState { return true }
        return false
    }

    var recordingStartedAt: Date? {
        if case .recording(_, let startedAt) = recordingState { return startedAt }
        return nil
    }

    var microphoneLevel: Float { capture.microphoneLevel }
    var callLevel: Float { capture.callLevel }

    let store = MeetingStore.shared
    private let capture = MeetingCaptureEngine()
    private let logger = Logger(subsystem: "com.ashadmohammed.voicer", category: "Meetings")
    private var modelContext: ModelContext?
    private var processingTail: Task<Void, Never>?
    private var storeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    /// What the call was, noted when the recording starts: the title the meeting is saved under.
    private var recordingCallName: String?

    private init() {
        capture.onProblem = { message in
            NotificationManager.shared.showNotification(title: message, type: .warning, duration: 6)
        }
        storeObserver = NotificationCenter.default.addObserver(
            forName: MeetingStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadMeetings() }
        }
        reloadMeetings()
    }

    /// History entries go into the app's own database.
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        CallDetector.shared.start()
        // Meetings saved while Apple's model was still downloading get their summary once it's ready.
        Task {
            await loadMeetings()
            summarisePendingMeetings()
        }
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.summarisePendingMeetings() }
        }
    }

    func reloadMeetings() {
        Task { await loadMeetings() }
    }

    private func loadMeetings() async {
        let store = self.store
        meetings = await Task.detached { store.loadAll() }.value
    }

    // MARK: - Recording

    func toggleRecording() {
        switch recordingState {
        case .idle: startRecording()
        case .recording: stopRecording()
        case .starting, .finishing: break
        }
    }

    func startRecording() {
        guard recordingState == .idle else { return }
        recordingState = .starting
        Task { await beginRecording() }
    }

    private func beginRecording() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        let id = UUID()
        do {
            let folder = try store.meetingFolder(for: id)
            // The same microphone dictation uses, so a meeting hears what the user set up.
            let microphone = AudioDeviceManager.shared.getCurrentDevice()
            try capture.start(folder: folder, microphoneDeviceID: microphone == 0 ? nil : microphone)
            recordingCallName = CallDetector.shared.currentCallName
            recordingState = .recording(id: id, startedAt: Date())
            MeetingIndicatorController.shared.show()
            logger.notice("Meeting recording started")
        } catch {
            recordingState = .idle
            try? FileManager.default.removeItem(at: store.dataFolder.appendingPathComponent(id.uuidString))
            logger.error("Meeting recording couldn't start: \(error.localizedDescription, privacy: .public)")
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Couldn't start the meeting recording: %@"), error.localizedDescription),
                type: .error,
                duration: 6
            )
        }
    }

    func stopRecording() {
        guard case .recording(let id, let startedAt) = recordingState else { return }
        recordingState = .finishing
        Task {
            let result = await capture.stop()
            recordingState = .idle
            MeetingIndicatorController.shared.hide()
            logger.notice("Meeting recording stopped after \(Int(result.duration)) s")

            let title = String(
                format: String(localized: "Meeting at %@"),
                startedAt.formatted(date: .omitted, time: .shortened))
            // Named after the call app; if the call wasn't recognised at the start, try once more now.
            let callName = recordingCallName ?? CallDetector.shared.currentCallName
            recordingCallName = nil
            enqueue(
                Job(id: id, title: title, stage: String(localized: "Waiting to start")),
                callName: callName,
                audio: .tracks(microphone: result.microphoneURL, call: result.callURL),
                source: .recorded,
                startedAt: startedAt,
                knownDuration: result.duration,
                warnings: result.warnings,
                importedFileName: nil
            )
            NotificationManager.shared.showNotification(
                title: String(localized: "Meeting recorded. Voicer is writing it up."),
                type: .info,
                duration: 3
            )
        }
    }

    // MARK: - Import

    func importRecording() {
        guard let url = MeetingImportPicker.chooseRecording() else { return }
        importRecording(at: url)
    }

    func importRecording(at url: URL) {
        let startedAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        enqueue(
            Job(id: UUID(), title: url.lastPathComponent, stage: String(localized: "Waiting to start")),
            audio: .singleRecording(url),
            source: .imported,
            startedAt: startedAt,
            knownDuration: nil,
            warnings: [],
            importedFileName: url.lastPathComponent
        )
    }

    // MARK: - Processing

    /// Meetings are processed one at a time; each loads its own speech models, and two at once would
    /// double the memory for no gain.
    private func enqueue(
        _ job: Job,
        callName: String? = nil,
        audio: MeetingAudio,
        source: MeetingRecord.Source,
        startedAt: Date,
        knownDuration: TimeInterval?,
        warnings: [String],
        importedFileName: String?
    ) {
        jobs.append(job)
        let previous = processingTail
        processingTail = Task { [weak self] in
            await previous?.value
            await self?.process(
                job, callName: callName, audio: audio, source: source, startedAt: startedAt, knownDuration: knownDuration,
                warnings: warnings, importedFileName: importedFileName)
        }
    }

    private func process(
        _ job: Job,
        callName: String?,
        audio: MeetingAudio,
        source: MeetingRecord.Source,
        startedAt: Date,
        knownDuration: TimeInterval?,
        warnings: [String],
        importedFileName: String?
    ) async {
        defer { jobs.removeAll { $0.id == job.id } }
        let jobID = job.id

        var record = MeetingRecord(
            id: job.id, title: "", startedAt: startedAt, duration: knownDuration ?? 0, source: source,
            importedFileName: importedFileName, notes: warnings)

        if let version = MeetingAudioAnalyzer.downloadedSpeechModels().first {
            do {
                let result = try await MeetingProcessor.process(audio, asrVersion: version) { [weak self] stage in
                    Task { @MainActor in self?.update(jobID, stage: stage) }
                }
                record.utterances = result.utterances
                record.notes += result.notes
                if result.duration > 0, knownDuration == nil || knownDuration == 0 { record.duration = result.duration }
                switch result.summary {
                case .summary(let summary):
                    record.summary = summary
                    // A recorded call keeps the call app's name; the generated title is shown as the note's topic.
                    record.title = source == .recorded ? "" : summary.title
                case .skipped(let reason):
                    record.summaryUnavailableReason = reason
                }
            } catch {
                logger.error("Meeting processing failed: \(error.localizedDescription, privacy: .public)")
                guard source == .recorded else {
                    NotificationManager.shared.showNotification(
                        title: String(format: String(localized: "Couldn't import %@: %@"), job.title, error.localizedDescription),
                        type: .error,
                        duration: 6
                    )
                    return
                }
                // A recording is never thrown away: it is saved untranscribed with the reason, audio kept.
                record.notes.append(
                    String(format: String(localized: "Voicer couldn't transcribe this meeting (%@). The audio is kept with the meeting."),
                           error.localizedDescription))
                record.summaryUnavailableReason = String(localized: "There is no transcript to summarise.")
            }
        } else {
            guard source == .recorded else {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Download Parakeet Ultra in Settings to import meetings."),
                    type: .warning,
                    duration: 6
                )
                return
            }
            record.notes.append(
                String(localized: "No Parakeet model is downloaded, so this meeting wasn't transcribed. The audio is kept with the meeting."))
            record.summaryUnavailableReason = String(localized: "There is no transcript to summarise.")
        }

        if source == .recorded {
            record.title = callName ?? String(localized: "Meeting")
        }

        // One mixed file (you and the call together) for the Documents folder, made before the tracks are compressed.
        var mixedAudioURL: URL?
        if case .tracks(let microphone, let call) = audio, MeetingStore.saveAudioToDocuments {
            update(jobID, stage: String(localized: "Saving audio"))
            if let folder = try? store.meetingFolder(for: record.id) {
                let tempURL = folder.appendingPathComponent("mixed.m4a")
                if await MeetingAudioArchiver.mixdown(microphone: microphone, call: call, to: tempURL) {
                    mixedAudioURL = tempURL
                } else {
                    record.notes.append(String(localized: "Voicer couldn't save the combined meeting audio to Documents."))
                }
            }
        }

        if case .tracks(let microphone, let call) = audio {
            update(jobID, stage: String(localized: "Saving"))
            var kept: [String] = []
            for url in [microphone, call].compactMap({ $0 }) {
                kept.append(await MeetingAudioArchiver.compress(url).lastPathComponent)
            }
            record.audioFileNames = kept
        }

        do {
            try store.save(&record)
        } catch {
            logger.error("Saving the meeting failed: \(error.localizedDescription, privacy: .public)")
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Couldn't save the meeting: %@"), error.localizedDescription),
                type: .error,
                duration: 6
            )
            return
        }

        // The note now has its file name, so the audio can take the same one and the note can link to it.
        if let mixedAudioURL {
            do {
                record.savedAudioFileName = try store.adoptSavedAudio(from: mixedAudioURL, for: record)
                try store.save(&record)
            } catch {
                logger.error("Saving the meeting audio to Documents failed: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: mixedAudioURL)
            }
        }
        addHistoryEntry(for: record, modelName: "Parakeet")

        let savedID = record.id
        NotificationManager.shared.showNotification(
            title: String(format: String(localized: "Meeting saved: %@"), record.displayTitle),
            type: .success,
            duration: 5,
            onTap: { MeetingsCoordinator.shared.openMeetingsPage(selecting: savedID) }
        )
    }

    private func update(_ jobID: UUID, stage: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].stage = stage
    }

    /// A History entry for the meeting, dated when it started so it doesn't become the "last transcription"
    /// that Paste Last pastes, unless nothing was dictated since.
    private func addHistoryEntry(for record: MeetingRecord, modelName: String) {
        guard let modelContext else { return }
        let entry = Transcription(
            text: historyText(for: record),
            duration: record.duration,
            transcriptionModelName: modelName,
            modeName: String(localized: "Meeting"),
            modeEmoji: "👥",
            transcriptionStatus: .completed
        )
        entry.timestamp = record.startedAt
        modelContext.insert(entry)
        do {
            try modelContext.save()
        } catch {
            logger.error("Couldn't add the meeting to History: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The text of a meeting's History entry: title, summary, action items and transcript.
    private func historyText(for record: MeetingRecord) -> String {
        var lines = [String(format: String(localized: "Meeting: %@"), record.displayTitle)]
        if let summary = record.summary {
            if !summary.keyPoints.isEmpty {
                lines.append("")
                lines.append(String(localized: "Summary"))
                lines += summary.keyPoints.map { "• \($0)" }
            }
            if !summary.actionItems.isEmpty {
                lines.append("")
                lines.append(String(localized: "Action items"))
                lines += summary.actionItems.map { "• \($0)" }
            }
        }
        if !record.utterances.isEmpty {
            lines.append("")
            lines.append(String(localized: "Transcript"))
            lines.append(record.transcriptText)
        }
        return lines.joined(separator: "\n")
    }

    /// Rewrites the meeting's History entry (found by its start time) after a summary was added later.
    private func refreshHistoryEntry(for record: MeetingRecord) {
        guard let modelContext else { return }
        let started = record.startedAt
        let descriptor = FetchDescriptor<Transcription>(predicate: #Predicate { $0.timestamp == started })
        guard let entries = try? modelContext.fetch(descriptor) else { return }
        let modeName = String(localized: "Meeting")
        for entry in entries where entry.modeName == modeName {
            entry.text = historyText(for: record)
        }
        try? modelContext.save()
    }

    // MARK: - Summaries

    /// Summarises every meeting that was saved without a summary only because Apple's model was still downloading.
    func summarisePendingMeetings() {
        guard MeetingSummarizer.isModelReady else { return }
        for record in meetings where record.isWaitingForSummaryModel { summarise(record, userAsked: false) }
    }

    /// Writes (or rewrites) a meeting's summary and updates its note. Runs in line with the transcription jobs,
    /// so Apple's model and the speech models are never loaded at the same time.
    func summarise(_ record: MeetingRecord, userAsked: Bool = true) {
        guard !record.utterances.isEmpty, !summarisingIDs.contains(record.id) else { return }
        summarisingIDs.insert(record.id)
        let id = record.id
        let previous = processingTail
        processingTail = Task { [weak self] in
            await previous?.value
            await self?.writeSummary(for: id, userAsked: userAsked)
        }
    }

    private func writeSummary(for id: UUID, userAsked: Bool) async {
        defer { summarisingIDs.remove(id) }
        let store = self.store
        let saved = await Task.detached { store.loadAll() }.value
        guard var record = saved.first(where: { $0.id == id }), !record.utterances.isEmpty else { return }

        let outcome = await MeetingSummarizer.summarize(transcript: MeetingTranscriptAssembler.plainText(record.utterances))
        switch outcome {
        case .summary(let summary):
            record.summary = summary
            record.summaryUnavailableReason = nil
            // A recording keeps the call app's name; an import is named after what was said.
            if record.source == .imported, record.title.trimmingCharacters(in: .whitespaces).isEmpty {
                record.title = summary.title
            }
        case .skipped(let reason):
            if record.summary == nil, record.summaryUnavailableReason != reason {
                record.summaryUnavailableReason = reason
            } else if userAsked {
                NotificationManager.shared.showNotification(title: reason, type: .warning, duration: 6)
                return
            } else {
                return
            }
        }

        do {
            try store.save(&record)
        } catch {
            logger.error("Saving the new summary failed: \(error.localizedDescription, privacy: .public)")
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Couldn't save the summary: %@"), error.localizedDescription),
                type: .error,
                duration: 6
            )
            return
        }
        refreshHistoryEntry(for: record)
        guard record.summary != nil, !userAsked else { return }
        NotificationManager.shared.showNotification(
            title: String(format: String(localized: "Summary added: %@"), record.displayTitle),
            type: .success,
            duration: 5,
            onTap: { MeetingsCoordinator.shared.openMeetingsPage(selecting: id) }
        )
    }

    // MARK: - Meetings page

    /// The meeting the Meetings page should open, set when a "saved" notification is tapped.
    @Published var selectedMeetingID: UUID?

    func openMeetingsPage(selecting id: UUID? = nil) {
        selectedMeetingID = id
        MainWindowNavigation.shared.navigate(to: .meetings)
        NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
    }

    func delete(_ record: MeetingRecord) {
        do {
            try store.delete(record)
        } catch {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Couldn't delete the meeting: %@"), error.localizedDescription),
                type: .error,
                duration: 5
            )
        }
    }
}
