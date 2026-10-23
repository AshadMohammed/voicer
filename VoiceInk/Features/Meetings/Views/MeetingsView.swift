import AppKit
import SwiftUI

/// The Meetings page: start or stop a recording, import a file, see what's being written up, and read past meetings.
struct MeetingsView: View {
    @ObservedObject private var coordinator = MeetingsCoordinator.shared
    @State private var openMeeting: MeetingRecord?

    var body: some View {
        ZStack {
            if let meeting = openMeeting {
                MeetingDetailView(meeting: meeting) {
                    openMeeting = nil
                }
                .transition(.opacity)
            } else {
                list
            }
        }
        .animation(.easeOut(duration: 0.16), value: openMeeting?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            coordinator.reloadMeetings()
            openRequestedMeeting()
        }
        .onChange(of: coordinator.selectedMeetingID) { _, _ in openRequestedMeeting() }
        .onChange(of: coordinator.meetings) { _, meetings in
            openRequestedMeeting()
            // A meeting deleted from its detail page closes it.
            if let open = openMeeting, !meetings.contains(where: { $0.id == open.id }) { openMeeting = nil }
        }
    }

    private func openRequestedMeeting() {
        guard let id = coordinator.selectedMeetingID,
            let meeting = coordinator.meetings.first(where: { $0.id == id })
        else { return }
        openMeeting = meeting
        coordinator.selectedMeetingID = nil
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AppPageHeader(eyebrow: "Library", title: "Meetings", subtitle: subtitle) {
                    HStack(spacing: 8) {
                        Button {
                            coordinator.importRecording()
                        } label: {
                            Label("Import a Recording", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(DashboardQuietButtonStyle())
                        .help("Transcribe and summarise an audio or video file as a meeting")

                        recordButton
                    }
                }

                if coordinator.recordingState != .idle {
                    MeetingRecordingCard(coordinator: coordinator)
                }

                ForEach(coordinator.jobs) { job in
                    MeetingJobRow(job: job)
                }

                if coordinator.meetings.isEmpty && coordinator.jobs.isEmpty {
                    MeetingsEmptyState()
                } else {
                    ForEach(daySections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            AppSectionLabel(verbatim: section.title)
                                .padding(.leading, 2)
                            VStack(spacing: 0) {
                                ForEach(Array(section.meetings.enumerated()), id: \.element.id) { index, meeting in
                                    if index > 0 {
                                        Rectangle().fill(AppTheme.Palette.line).frame(height: 1)
                                    }
                                    MeetingRow(meeting: meeting) { openMeeting = meeting }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
                            .appSurfaceCard()
                        }
                    }
                }

                MeetingsSettingsCard(notesFolder: coordinator.store.notesFolder)
            }
            .padding(.horizontal, 40)
            .padding(.top, 64)
            .padding(.bottom, 32)
        }
    }

    private var subtitle: LocalizedStringKey {
        let count = coordinator.meetings.count
        if count == 0 { return "Recorded, written up and summarised on this Mac." }
        return count == 1 ? "1 meeting, kept on this Mac." : "\(count) meetings, kept on this Mac."
    }

    @ViewBuilder
    private var recordButton: some View {
        switch coordinator.recordingState {
        case .recording:
            Button {
                coordinator.stopRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.fill")
            }
            .buttonStyle(MeetingAccentButtonStyle())
        case .idle:
            Button {
                coordinator.startRecording()
            } label: {
                Label("Start Meeting", systemImage: "record.circle")
            }
            .buttonStyle(MeetingAccentButtonStyle())
            .help("Record your microphone and the call's audio")
        case .starting, .finishing:
            Button {} label: {
                Label("Start Meeting", systemImage: "record.circle")
            }
            .buttonStyle(MeetingAccentButtonStyle())
            .disabled(true)
        }
    }

    private struct DaySection {
        let title: String
        let meetings: [MeetingRecord]
    }

    private var daySections: [DaySection] {
        let calendar = Calendar.current
        var sections: [DaySection] = []
        for meeting in coordinator.meetings {
            let title = Self.dayTitle(for: meeting.startedAt, calendar: calendar)
            if let last = sections.last, last.title == title {
                sections[sections.count - 1] = DaySection(title: title, meetings: last.meetings + [meeting])
            } else {
                sections.append(DaySection(title: title, meetings: [meeting]))
            }
        }
        return sections
    }

    private static func dayTitle(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        return sameYear
            ? date.formatted(.dateTime.weekday(.wide).day().month(.wide))
            : date.formatted(.dateTime.day().month(.wide).year())
    }
}

// MARK: - Pieces of the list

struct MeetingAccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appSans(13, weight: .semibold))
            .foregroundStyle(AppTheme.Text.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.Palette.accent.opacity(configuration.isPressed ? 0.8 : (isEnabled ? 1 : 0.5)))
            )
    }
}

private struct MeetingRecordingCard: View {
    @ObservedObject var coordinator: MeetingsCoordinator

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(AppTheme.Palette.recording)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(coordinator.isRecording ? "Recording this meeting" : "Getting the recording ready")
                    .font(.appSans(14, weight: .semibold))
                    .foregroundStyle(AppTheme.Palette.ink)
                Text("Your microphone and the call's audio are recorded as two tracks. Let people know you're recording.")
                    .font(.appSans(12))
                    .foregroundStyle(AppTheme.Palette.muted)
            }
            Spacer(minLength: 12)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsed(at: context.date))
                    .font(.appNumber(22, weight: .medium))
                    .foregroundStyle(AppTheme.Palette.ink)
            }
        }
        .padding(16)
        .appSurfaceCard(fill: AppTheme.Accent.fillSubtle)
    }

    private func elapsed(at date: Date) -> String {
        guard let start = coordinator.recordingStartedAt else { return "0:00" }
        return MeetingTranscriptAssembler.timestamp(max(0, date.timeIntervalSince(start)))
    }
}

private struct MeetingJobRow: View {
    let job: MeetingsCoordinator.Job

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .font(.appSans(13.5, weight: .semibold))
                    .foregroundStyle(AppTheme.Palette.ink)
                    .lineLimit(1)
                Text(job.stage)
                    .font(.appSans(12))
                    .foregroundStyle(AppTheme.Palette.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .appSurfaceCard()
    }
}

private struct MeetingRow: View {
    let meeting: MeetingRecord
    let onOpen: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                Image(systemName: meeting.source == .imported ? "waveform" : "person.2")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.Palette.accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(AppTheme.Accent.fillSubtle))

                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.displayTitle)
                        .font(.appSans(14, weight: .semibold))
                        .foregroundStyle(AppTheme.Palette.ink)
                        .lineLimit(1)
                    Text(detailLine)
                        .font(.appSans(12))
                        .foregroundStyle(AppTheme.Palette.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(MeetingDuration.short(meeting.duration))
                    .font(.appNumber(13))
                    .foregroundStyle(AppTheme.Palette.inkSoft)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Palette.faint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isHovering ? AppTheme.Palette.ink.opacity(0.03) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var detailLine: String {
        var parts = [meeting.startedAt.formatted(date: .omitted, time: .shortened)]
        let speakers = Set(meeting.utterances.map(\.speaker)).count
        if speakers > 0 {
            parts.append(speakers == 1 ? String(localized: "1 speaker") : String(format: String(localized: "%lld speakers"), Int64(speakers)))
        }
        if let items = meeting.summary?.actionItems.count, items > 0 {
            parts.append(items == 1 ? String(localized: "1 action item") : String(format: String(localized: "%lld action items"), Int64(items)))
        }
        if meeting.source == .imported, let name = meeting.importedFileName {
            parts.append(name)
        }
        return parts.joined(separator: " · ")
    }
}

private struct MeetingsEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(AppTheme.Palette.accent)
            Text("No meetings yet")
                .font(.appSerif(22))
                .foregroundStyle(AppTheme.Palette.ink)
            Text(
                "Start a meeting here or from the menu bar. Voicer records your microphone and the call's audio, then writes out who said what and a short summary, all on this Mac."
            )
            .font(.appSans(13))
            .foregroundStyle(AppTheme.Palette.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .appSurfaceCard()
    }
}

private struct MeetingsSettingsCard: View {
    let notesFolder: URL
    @AppStorage(CallDetector.settingKey) private var askToRecordCalls = true
    @AppStorage(MeetingStore.saveAudioToDocumentsKey) private var saveAudioToDocuments = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AppSectionLabel("Settings")
                .padding(.leading, 2)
            VStack(spacing: 0) {
                row(
                    title: "Ask to record when a call starts",
                    detail: "When Zoom, Teams, FaceTime, Slack, Webex, Discord or a meeting tab in your browser starts using the microphone, Voicer offers to record. It never records without a click."
                ) {
                    Toggle("", isOn: $askToRecordCalls)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                Rectangle().fill(AppTheme.Palette.line).frame(height: 1)
                row(
                    title: "Save meeting audio to Documents",
                    detail: "After a meeting, keeps one recording of you and the call together beside the note, with the same name."
                ) {
                    Toggle("", isOn: $saveAudioToDocuments)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                Rectangle().fill(AppTheme.Palette.line).frame(height: 1)
                row(title: "Start or stop a meeting", detail: "A shortcut that works from any app. None is set at first.") {
                    ShortcutRecorder(action: .toggleMeetingRecording)
                        .controlSize(.small)
                }
                Rectangle().fill(AppTheme.Palette.line).frame(height: 1)
                row(title: "Notes folder", detail: LocalizedStringKey(notesFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))) {
                    Button("Open") {
                        try? FileManager.default.createDirectory(at: notesFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(notesFolder)
                    }
                    .buttonStyle(DashboardQuietButtonStyle())
                }
                Rectangle().fill(AppTheme.Palette.line).frame(height: 1)
                row(
                    title: "Call audio permission",
                    detail: "macOS asks the first time. If calls come out silent, allow Voicer under Screen & System Audio Recording."
                ) {
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(DashboardQuietButtonStyle())
                }
            }
            .appSurfaceCard()
        }
    }

    private func row<Trailing: View>(
        title: LocalizedStringKey, detail: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.appSans(13.5, weight: .semibold))
                    .foregroundStyle(AppTheme.Palette.ink)
                Text(detail)
                    .font(.appSans(12))
                    .foregroundStyle(AppTheme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

enum MeetingDuration {
    /// "42 min", "1 h 05 min", "35 s".
    static func short(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? String(format: "%d h %02d min", hours, minutes) : "\(minutes) min"
    }
}
