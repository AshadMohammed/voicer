import Foundation

enum MeetingMarkdown {
    /// Renders a `MeetingRecord` as a human-readable Markdown note.
    static func render(_ record: MeetingRecord) -> String {
        var lines: [String] = []

        // ── Title ──────────────────────────────────────────────────────────
        lines.append("# \(record.displayTitle)")
        lines.append("")

        // ── Header line ────────────────────────────────────────────────────
        lines.append(headerLine(for: record))
        lines.append("")

        // ── Notes (blockquotes) ────────────────────────────────────────────
        if !record.notes.isEmpty {
            for note in record.notes {
                lines.append("> \(note)")
                lines.append(">")
            }
            // Remove the trailing blank blockquote line.
            if lines.last == ">" { lines.removeLast() }
            lines.append("")
        }

        // ── Summary ────────────────────────────────────────────────────────
        lines.append("## Summary")
        if let summary = record.summary {
            for point in summary.keyPoints {
                lines.append("- \(point)")
            }
            if summary.keyPoints.isEmpty {
                lines.append("_Nothing notable was captured._")
            }
        } else if let reason = record.summaryUnavailableReason {
            lines.append("_No summary: \(reason)_")
        } else {
            lines.append("_No summary available._")
        }
        lines.append("")

        // ── Action items (only when there is a summary) ────────────────────
        if let summary = record.summary {
            lines.append("## Action items")
            if summary.actionItems.isEmpty {
                lines.append("_None noted._")
            } else {
                for item in summary.actionItems {
                    lines.append("- [ ] \(item)")
                }
            }
            lines.append("")
        }

        // ── Transcript ─────────────────────────────────────────────────────
        lines.append("## Transcript")
        if record.utterances.isEmpty {
            lines.append("_Nothing was transcribed._")
        } else {
            var first = true
            for utterance in record.utterances {
                if !first { lines.append("") }
                first = false
                let ts = MeetingTranscriptAssembler.timestamp(utterance.start)
                lines.append("**[\(ts)] \(utterance.speaker):** \(utterance.text)")
            }
        }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    // MARK: - Private helpers

    private static func headerLine(for record: MeetingRecord) -> String {
        let datePart = formattedDate(record.startedAt)
        let lengthPart = formattedDuration(record.duration)
        let sourcePart: String
        switch record.source {
        case .recorded:
            sourcePart = "Recorded with Voicer"
        case .imported:
            let name = record.importedFileName ?? "unknown file"
            sourcePart = "Imported from \(name)"
        }
        return "**Date:** \(datePart) · **Length:** \(lengthPart) · \(sourcePart)"
    }

    private static func formattedDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .full
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    private static func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%d h %02d min", hours, minutes)
        } else if minutes > 0 {
            return "\(minutes) min"
        } else {
            return "\(secs) sec"
        }
    }
}

