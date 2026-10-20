import AppKit
import UniformTypeIdentifiers

@MainActor
enum MeetingImportPicker {
    /// Shows an Open panel for one audio or video file.
    /// - Returns: The chosen file URL, or `nil` when the user cancels.
    static func chooseRecording() -> URL? {
        // Voicer is often menu-bar only, so bring it forward first.
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title           = "Import a Recording as a Meeting"
        panel.prompt          = "Import"
        panel.message         = "Voicer will transcribe it, tell the speakers apart and write a summary, all on this Mac."
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true

        return panel.runModal() == .OK ? panel.url : nil
    }
}

