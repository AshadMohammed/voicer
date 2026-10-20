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
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Meetings")
    private var modelContext: ModelContext?
    private var processingTail: Task<Void, Never>?
    private var storeObserver: NSObjectProtocol?

    private init() {
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
    }

    func reloadMeetings() {
        let store = self.store
        Task {
            let loaded = await Task.detached { store.loadAll() }.value
            self.meetings = loaded
        }
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
            enqueue(
                Job(id: id, title: title, stage: String(localized: "Waiting to start")),
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
                job, audio: audio, source: source, startedAt: startedAt, knownDuration: knownDuration,
                warnings: warnings, importedFileName: importedFileName)
        }
    }

    private func process(
        _ job: Job,
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
                let result = try await MeetingProcessor.process(audio, asrVersion: version) { stage in
                    Task { @MainActor [weak self] in self?.update(jobID, stage: stage) }
                }
                record.utterances = result.utterances
                record.notes += result.notes
                if result.duration > 0, knownDuration == nil || knownDuration == 0 { record.duration = result.duration }
                switch result.summary {
                case .summary(let summary):
                    record.summary = summary
                    record.title = summary.title
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
                    title: String(localized: "Download a Parakeet model in AI Models to import meetings."),
                    type: .warning,
                    duration: 6
                )
                return
            }
            record.notes.append(
                String(localized: "No Parakeet model is downloaded, so this meeting wasn't transcribed. The audio is kept with the meeting."))
            record.summaryUnavailableReason = String(localized: "There is no transcript to summarise.")
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

        let entry = Transcription(
            text: lines.joined(separator: "\n"),
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
