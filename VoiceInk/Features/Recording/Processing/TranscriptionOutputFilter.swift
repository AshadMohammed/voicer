import Foundation

struct TranscriptionOutputFilter {
    private static let hallucinationPatterns = [
        #"\[.*?\]"#,  // []
        #"\(.*?\)"#,  // ()
        #"\{.*?\}"#,  // {}
    ]

    // MARK: - Stock phrases

    /// Phrases a speech model writes on its own when it hears silence ("Thank you for watching"), as normalised
    /// words, longest first so the longer phrase wins.
    private static let stockPhrases: [[String]] = [
        "thank you for watching", "thanks for watching", "please subscribe", "subscribe to my channel",
    ]
    .map { $0.split(separator: " ").map(String.init) }
    .sorted { $0.count > $1.count }

    /// Lowercased words: punctuation is dropped (apostrophes vanish, other marks act as a space) and whitespace collapsed.
    private static func echoTokens(_ text: String) -> [String] {
        var spaced = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if scalar == "'" || scalar == "\u{2019}" { continue }
            spaced.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
        }
        return String(spaced).split(separator: " ").map(String.init)
    }

    /// True when the whole text, normalised, is made only of stock phrases (one or several in a row).
    static func isOnlyStockEchoPhrases(_ text: String) -> Bool {
        let tokens = echoTokens(text)
        guard !tokens.isEmpty else { return false }
        var covered = 0
        var index = 0
        while index < tokens.count {
            if let phrase = stockPhrases.first(where: { phrase in
                index + phrase.count <= tokens.count && Array(tokens[index..<index + phrase.count]) == phrase
            }) {
                covered += phrase.count
                index += phrase.count
            } else {
                index += 1
            }
        }
        return covered == tokens.count
    }

    static func filter(_ text: String) -> String {
        var filteredText = text

        // Remove <TAG>...</TAG> blocks
        let tagBlockPattern = #"<([A-Za-z][A-Za-z0-9:_-]*)[^>]*>[\s\S]*?</\1>"#
        if let regex = try? NSRegularExpression(pattern: tagBlockPattern) {
            let range = NSRange(filteredText.startIndex..., in: filteredText)
            filteredText = regex.stringByReplacingMatches(in: filteredText, options: [], range: range, withTemplate: "")
        }

        // Remove bracketed hallucinations
        for pattern in hallucinationPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(filteredText.startIndex..., in: filteredText)
                filteredText = regex.stringByReplacingMatches(
                    in: filteredText, options: [], range: range, withTemplate: "")
            }
        }

        // Remove configured filler words. An empty list is naturally a no-op.
        for fillerWord in FillerWordManager.shared.fillerWords {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: fillerWord))\\b[,.]?"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(filteredText.startIndex..., in: filteredText)
                filteredText = regex.stringByReplacingMatches(
                    in: filteredText, options: [], range: range, withTemplate: "")
            }
        }

        // Clean whitespace
        filteredText = filteredText.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        filteredText = filteredText.trimmingCharacters(in: .whitespacesAndNewlines)

        return filteredText
    }
}
