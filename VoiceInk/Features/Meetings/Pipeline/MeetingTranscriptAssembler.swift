import Foundation

/// A recognised word and when it was said, in seconds from the start of the meeting.
struct MeetingWord: Sendable, Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

/// A stretch of the meeting in which one diarized voice is talking.
struct MeetingSpeakerSpan: Sendable, Equatable {
    let speakerID: String
    let start: TimeInterval
    let end: TimeInterval
}

/// One person's turn in the finished transcript.
struct MeetingUtterance: Sendable, Codable, Equatable {
    var speaker: String
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

/// Builds a readable, time-ordered transcript out of timed words and speaker turns.
/// Pure logic with no audio or model code, so it can be checked on its own.
enum MeetingTranscriptAssembler {
    static let ownSpeakerName = "You"
    static let unknownSpeakerName = "Others"

    /// Groups one person's words into utterances, starting a new one after a pause.
    static func utterances(
        from words: [MeetingWord],
        speaker: String,
        pause: TimeInterval = 1.2
    ) -> [MeetingUtterance] {
        var result: [MeetingUtterance] = []
        for word in words {
            if var last = result.last, last.speaker == speaker, word.start - last.end <= pause {
                last.text += " " + word.text
                last.end = max(last.end, word.end)
                result[result.count - 1] = last
            } else {
                result.append(MeetingUtterance(speaker: speaker, start: word.start, end: word.end, text: word.text))
            }
        }
        return result
    }

    /// Gives each word the diarized voice that overlaps it most, then groups the words into utterances.
    /// Words that fall in no turn take the nearest turn within two seconds, or the previous word's voice.
    static func utterances(
        from words: [MeetingWord],
        spans: [MeetingSpeakerSpan],
        names: [String: String],
        pause: TimeInterval = 1.2
    ) -> [MeetingUtterance] {
        guard !spans.isEmpty else {
            return utterances(from: words, speaker: unknownSpeakerName, pause: pause)
        }

        let sortedSpans = spans.sorted { $0.start < $1.start }
        var labels: [String?] = []
        var previous: String?
        for word in words {
            let speakerID = bestSpeaker(for: word, in: sortedSpans) ?? previous
            labels.append(speakerID)
            previous = speakerID
        }
        labels = absorbingStrayVoices(labels, words: words)

        var result: [MeetingUtterance] = []
        for (word, speakerID) in zip(words, labels) {
            let name = speakerID.flatMap { names[$0] } ?? unknownSpeakerName
            if var last = result.last, last.speaker == name, word.start - last.end <= pause {
                last.text += " " + word.text
                last.end = max(last.end, word.end)
                result[result.count - 1] = last
            } else {
                result.append(MeetingUtterance(speaker: name, start: word.start, end: word.end, text: word.text))
            }
        }
        return result
    }

    /// The diarizer sometimes invents a voice for a second or two of someone's speech. A voice with
    /// under 2.5 s of words that is also under a tenth of the talking is folded into its neighbour.
    private static func absorbingStrayVoices(_ labels: [String?], words: [MeetingWord]) -> [String?] {
        var talkTime: [String: TimeInterval] = [:]
        var total: TimeInterval = 0
        for (word, label) in zip(words, labels) {
            let length = max(word.end - word.start, 0.05)
            total += length
            if let label { talkTime[label, default: 0] += length }
        }
        let stray = Set(talkTime.filter { $0.value < 2.5 && $0.value < total * 0.1 }.keys)
        guard !stray.isEmpty, stray.count < talkTime.count else { return labels }

        // Each run of stray words joins whichever real voice is closest in time, before or after it.
        var result = labels
        var index = 0
        while index < result.count {
            guard let label = result[index], stray.contains(label) else {
                index += 1
                continue
            }
            var runEnd = index
            while runEnd + 1 < result.count, let next = result[runEnd + 1], stray.contains(next) { runEnd += 1 }

            let before = index > 0 ? result[index - 1] : nil
            let after = runEnd + 1 < result.count ? result[runEnd + 1] : nil
            let gapBefore = index > 0 ? words[index].start - words[index - 1].end : .infinity
            let gapAfter = runEnd + 1 < words.count ? words[runEnd + 1].start - words[runEnd].end : .infinity
            let replacement = (gapAfter < gapBefore ? after : before) ?? before ?? after
            for position in index...runEnd { result[position] = replacement }
            index = runEnd + 1
        }
        return result
    }

    private static func bestSpeaker(for word: MeetingWord, in spans: [MeetingSpeakerSpan]) -> String? {
        var best: (id: String, overlap: TimeInterval)?
        var nearest: (id: String, distance: TimeInterval)?

        for span in spans {
            if span.start > word.end + 2 { break }
            let overlap = min(span.end, word.end) - max(span.start, word.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) {
                best = (span.speakerID, overlap)
            }
            let distance = max(span.start - word.end, word.start - span.end, 0)
            if distance <= 2, distance < (nearest?.distance ?? .infinity) {
                nearest = (span.speakerID, distance)
            }
        }
        return best?.id ?? nearest?.id
    }

    /// Display names for diarized voices, numbered in the order they first speak.
    static func speakerNames(for spans: [MeetingSpeakerSpan], firstNumber: Int) -> [String: String] {
        var names: [String: String] = [:]
        var next = firstNumber
        for span in spans.sorted(by: { $0.start < $1.start }) where names[span.speakerID] == nil {
            names[span.speakerID] = "Speaker \(next)"
            next += 1
        }
        return names
    }

    /// Drops words from your microphone that are really the call playing through your speakers:
    /// the same word was heard on the call audio within a second of it.
    static func removingEcho(
        from ownWords: [MeetingWord],
        heardIn callWords: [MeetingWord],
        tolerance: TimeInterval = 1.0
    ) -> [MeetingWord] {
        guard !callWords.isEmpty else { return ownWords }
        let heard = callWords.map { (word: normalized($0.text), start: $0.start) }.sorted { $0.start < $1.start }
        let starts = heard.map(\.start)

        return ownWords.filter { word in
            let text = normalized(word.text)
            guard !text.isEmpty else { return false }
            var index = lowerBound(starts, word.start - tolerance)
            while index < heard.count, heard[index].start <= word.start + tolerance {
                if heard[index].word == text { return false }
                index += 1
            }
            return true
        }
    }

    /// After echo removal, a couple of misheard words can remain from the call leaking into the mic.
    /// Short "You" lines spoken while the call was talking are dropped.
    static func droppingEchoScraps(
        _ own: [MeetingUtterance],
        callWords: [MeetingWord],
        maxWords: Int = 2
    ) -> [MeetingUtterance] {
        guard !callWords.isEmpty else { return own }
        let starts = callWords.map(\.start).sorted()
        return own.filter { utterance in
            guard utterance.text.split(separator: " ").count <= maxWords else { return true }
            let index = lowerBound(starts, utterance.start - 0.5)
            let callTalking = index < starts.count && starts[index] <= utterance.end + 0.5
            return !callTalking
        }
    }

    private static func lowerBound(_ sorted: [TimeInterval], _ value: TimeInterval) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Puts everyone's utterances in time order and joins back-to-back turns by the same person.
    static func merged(_ groups: [[MeetingUtterance]], joinGap: TimeInterval = 2.0) -> [MeetingUtterance] {
        let all = groups.flatMap { $0 }.sorted { $0.start < $1.start }
        var result: [MeetingUtterance] = []
        for utterance in all {
            if var last = result.last, last.speaker == utterance.speaker, utterance.start - last.end <= joinGap {
                last.text += " " + utterance.text
                last.end = max(last.end, utterance.end)
                result[result.count - 1] = last
            } else {
                result.append(utterance)
            }
        }
        return result
    }

    /// The transcript as plain lines, one turn per line, used for the summary and for History.
    static func plainText(_ utterances: [MeetingUtterance]) -> String {
        utterances.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
