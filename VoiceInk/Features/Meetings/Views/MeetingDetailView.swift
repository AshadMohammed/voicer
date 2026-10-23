import AppKit
import SwiftUI

/// One meeting: summary, action items and the transcript, with the note one click away.
struct MeetingDetailView: View {
    let meeting: MeetingRecord
    let onBack: () -> Void
    @State private var confirmingDelete = false
    @State private var copied = false

    private var noteURL: URL { MeetingsCoordinator.shared.store.noteURL(for: meeting) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button(action: onBack) {
                    Label("Meetings", systemImage: "chevron.left")
                        .font(.appSans(13, weight: .medium))
                        .foregroundStyle(AppTheme.Palette.muted)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                header

                if !meeting.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(meeting.notes, id: \.self) { note in
                            Label {
                                Text(note)
                                    .font(.appSans(12.5))
                                    .foregroundStyle(AppTheme.Palette.inkSoft)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(AppTheme.Palette.accent)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appSurfaceCard(fill: AppTheme.Accent.fillSubtle)
                }

                section("Summary") {
                    if let summary = meeting.summary, !summary.keyPoints.isEmpty {
                        bullets(summary.keyPoints, marker: "circle.fill", markerSize: 5)
                    } else {
                        Text(meeting.summaryUnavailableReason ?? String(localized: "No summary for this meeting."))
                            .font(.appSans(13))
                            .foregroundStyle(AppTheme.Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let summary = meeting.summary {
                    section("Action items") {
                        if summary.actionItems.isEmpty {
                            Text("None noted.")
                                .font(.appSans(13))
                                .foregroundStyle(AppTheme.Palette.muted)
                        } else {
                            bullets(summary.actionItems, marker: "square", markerSize: 11)
                        }
                    }
                }

                section("Transcript") {
                    if meeting.utterances.isEmpty {
                        Text("Nothing was transcribed.")
                            .font(.appSans(13))
                            .foregroundStyle(AppTheme.Palette.muted)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(meeting.utterances.enumerated()), id: \.offset) { _, line in
                                transcriptLine(line)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 52)
            .padding(.bottom, 32)
        }
        .confirmationDialog(
            "Delete this meeting?", isPresented: $confirmingDelete
        ) {
            Button("Delete", role: .destructive) {
                MeetingsCoordinator.shared.delete(meeting)
                onBack()
            }
        } message: {
            Text("The note moves to the Trash and the recording is deleted.")
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                AppSectionLabel(verbatim: meeting.startedAt.formatted(date: .complete, time: .shortened))
                Text(meeting.displayTitle)
                    .font(.appSerif(30))
                    .foregroundStyle(AppTheme.Palette.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(metaLine)
                    .font(.appSans(13))
                    .foregroundStyle(AppTheme.Palette.muted)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy Transcript") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meeting.transcriptText, forType: .string)
                    copied = true
                }
                .buttonStyle(DashboardQuietButtonStyle())
                .disabled(meeting.utterances.isEmpty)

                Button("Open Note") { NSWorkspace.shared.open(noteURL) }
                    .buttonStyle(MeetingAccentButtonStyle())

                Menu {
                    Button("Show Note in Finder") { NSWorkspace.shared.activateFileViewerSelecting([noteURL]) }
                    if let audioURL = MeetingsCoordinator.shared.store.savedAudioURL(for: meeting) {
                        Button("Open Audio") { NSWorkspace.shared.open(audioURL) }
                    }
                    Button("Show Recording in Finder") {
                        let folder = MeetingsCoordinator.shared.store.dataFolder
                            .appendingPathComponent(meeting.id.uuidString, isDirectory: true)
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    .disabled(meeting.audioFileNames.isEmpty)
                    Divider()
                    Button("Delete Meeting…", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.Palette.inkSoft)
                        .frame(width: 34, height: 32)
                        .appSurfaceCard(cornerRadius: 8)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private var metaLine: String {
        var parts = [MeetingDuration.short(meeting.duration)]
        let speakers = Set(meeting.utterances.map(\.speaker)).count
        if speakers > 0 {
            parts.append(speakers == 1 ? String(localized: "1 speaker") : String(format: String(localized: "%lld speakers"), Int64(speakers)))
        }
        parts.append(
            meeting.source == .imported
                ? String(format: String(localized: "Imported from %@"), meeting.importedFileName ?? "a file")
                : String(localized: "Recorded with Voicer"))
        return parts.joined(separator: " · ")
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AppSectionLabel(title)
                .padding(.leading, 2)
            content()
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appSurfaceCard()
        }
    }

    private func bullets(_ items: [String], marker: String, markerSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: marker)
                        .font(.system(size: markerSize, weight: .medium))
                        .foregroundStyle(AppTheme.Palette.accent)
                        .frame(width: 12)
                    Text(item)
                        .font(.appSans(13.5))
                        .foregroundStyle(AppTheme.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func transcriptLine(_ line: MeetingUtterance) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(MeetingTranscriptAssembler.timestamp(line.start))
                .font(.appNumber(11.5))
                .foregroundStyle(AppTheme.Palette.faint)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.speaker)
                    .font(.appSans(12, weight: .semibold))
                    .foregroundStyle(speakerColor(line.speaker))
                Text(line.text)
                    .font(.appSans(13.5))
                    .foregroundStyle(AppTheme.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// "You" in the accent; other voices in steady, distinguishable tones from the palette.
    private func speakerColor(_ speaker: String) -> Color {
        if speaker == MeetingTranscriptAssembler.ownSpeakerName { return AppTheme.Palette.accent }
        let tones = [AppTheme.Palette.olive, AppTheme.Palette.tan, AppTheme.Palette.inkSoft, AppTheme.Palette.muted]
        let number = Int(speaker.split(separator: " ").last ?? "") ?? 0
        return tones[number % tones.count]
    }
}
