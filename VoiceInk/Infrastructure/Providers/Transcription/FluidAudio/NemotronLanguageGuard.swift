import Foundation

/// Nemotron writes every utterance in Devanagari when left on auto, English included.
/// Real Hindi always carries a few small function words; a Devanagari line without any is English heard as Hindi.
enum NemotronLanguageGuard {
    private static let hindiFunctionWords: Set<String> = [
        "है", "हैं", "हूं", "हूँ", "था", "थी", "थे", "में", "का", "की", "के", "को", "से", "पर", "और", "नहीं",
        "तो", "ये", "वो", "यह", "वह", "कि", "भी", "कुछ", "मैं", "मुझे", "मेरा", "मेरी", "हम", "आप", "तुम", "क्या",
        "कोई", "ही", "जो", "लिए", "रहा", "रही", "रहे", "करना", "करो", "बहुत", "अगर", "लेकिन", "तक", "अब",
    ]

    /// Longest recording kept for a second pass (5 minutes at 16 kHz); longer ones keep the first result.
    static let maxReplaySamples = 16_000 * 300

    static func needsEnglishPass(_ text: String) -> Bool {
        guard text.unicodeScalars.contains(where: { (0x0900...0x097F).contains($0.value) }) else { return false }
        let words = text.split { !$0.isLetter && $0 != "\u{0901}" && $0 != "\u{0902}" && $0 != "\u{093C}" && !$0.unicodeScalars.contains(where: { (0x093E...0x094D).contains($0.value) }) }
        return !words.contains { hindiFunctionWords.contains(String($0)) }
    }
}
