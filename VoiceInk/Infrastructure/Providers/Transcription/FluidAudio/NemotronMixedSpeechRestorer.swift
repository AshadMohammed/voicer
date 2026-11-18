import Foundation

/// Restores English spellings inside Nemotron's Devanagari transcript.
enum NemotronMixedSpeechRestorer {
    struct TimedWord: Sendable {
        let text: String
        let start: Double
        let end: Double
    }

    /// CMU pronunciations: `word<TAB>frequency rank<TAB>pronunciation;pronunciation`.
    /// Rank 0 marks pronunciation-only words outside the top 40k (contractions, names).
    struct Lexicon: Sendable {
        private struct Entry: Sendable {
            let word: String
            let rank: Int
            let phones: [Character]
        }

        private let entriesByLength: [Int: [Entry]]
        private let entriesByWord: [String: [[Character]]]

        init?(url: URL) {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            var entries: [Int: [Entry]] = [:]
            var words: [String: [[Character]]] = [:]

            for line in contents.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 3, let rank = Int(fields[1]) else { continue }
                let word = String(fields[0])
                for pronunciation in fields[2].split(separator: ";") {
                    let phones = Self.arpaPhones(String(pronunciation))
                    guard !phones.isEmpty else { continue }
                    if rank > 0 {
                        entries[phones.count, default: []].append(
                            Entry(word: word, rank: rank, phones: phones)
                        )
                    }
                    words[word, default: []].append(phones)
                }
            }

            entriesByLength = entries
            entriesByWord = words
        }

        fileprivate func pronunciations(for word: String) -> [[Character]]? {
            if let exact = entriesByWord[word] { return exact }
            return entriesByWord[word.replacingOccurrences(of: "'", with: "")]
        }

        fileprivate func closestWord(to phones: [Character]) -> (String?, Double) {
            guard !phones.isEmpty else { return (nil, 9) }
            var bestWord: String?
            var bestScore = 9.0
            let minimumLength = max(1, phones.count - 3)
            let maximumLength = phones.count + 3

            for length in minimumLength...maximumLength {
                for entry in entriesByLength[length] ?? [] {
                    let score = Self.distance(phones, entry.phones) + 0.04 * log10(Double(entry.rank))
                    if score < bestScore {
                        bestWord = entry.word
                        bestScore = score
                    }
                }
            }
            return (bestWord, bestScore)
        }

        private static func arpaPhones(_ pronunciation: String) -> [Character] {
            var result: [Character] = []
            for phone in pronunciation.split(whereSeparator: \.isWhitespace) {
                let base = phone.filter { !$0.isNumber }
                if base == "AH", phone.last == "0" {
                    result.append("ə")
                } else if let mapped = arpa[String(base)] {
                    result.append(contentsOf: mapped)
                }
            }
            return result
        }

        private static let arpa: [String: String] = [
            "P": "p", "B": "b", "T": "t", "D": "d", "K": "k", "G": "g", "CH": "c", "JH": "j",
            "F": "f", "V": "v", "TH": "t", "DH": "d", "S": "s", "Z": "z", "SH": "S", "ZH": "z",
            "HH": "h", "M": "m", "N": "n", "NG": "ng", "L": "l", "R": "r", "Y": "y", "W": "v",
            "AA": "a", "AE": "e", "AH": "a", "AO": "O", "AW": "au", "AY": "ai", "EH": "e",
            "ER": "ər", "EY": "e", "IH": "i", "IY": "i", "OW": "o", "OY": "Oi", "UH": "u", "UW": "u",
        ]

        private static let vowels = Set("aeiouOə")

        private static let softConsonants = Set("hry")

        private static func substitutionCost(_ left: Character, _ right: Character) -> Double {
            if left == right { return 0 }
            switch (left, right) {
            case ("z", "j"), ("j", "z"): return 0.3
            case ("s", "z"), ("z", "s"): return 0.3
            case ("s", "S"), ("S", "s"): return 0.4
            case ("k", "g"), ("g", "k"): return 0.6
            case ("t", "d"), ("d", "t"): return 0.6
            case ("p", "b"), ("b", "p"): return 0.6
            case ("p", "f"), ("f", "p"): return 0.5
            case ("n", "m"), ("m", "n"): return 0.5
            case ("n", "N"), ("N", "n"): return 0.2
            case ("m", "N"), ("N", "m"): return 0.3
            case ("v", "b"), ("b", "v"): return 0.7
            case ("O", "a"), ("a", "O"), ("O", "o"), ("o", "O"): return 0.1
            case ("i", "e"), ("e", "i"): return 0.25
            case ("u", "o"), ("o", "u"): return 0.25
            case ("y", "i"), ("i", "y"): return 0.4
            case ("v", "u"), ("u", "v"): return 0.4
            default:
                if left == "ə" || right == "ə" {
                    return vowels.contains(left) || vowels.contains(right) ? 0.1 : 1
                }
                return vowels.contains(left) && vowels.contains(right) ? 0.35 : 1
            }
        }

        private static func indelCost(_ phone: Character) -> Double {
            if phone == "ə" { return 0.15 }
            if phone == "N" { return 0.2 }
            if vowels.contains(phone) { return 0.4 }
            if softConsonants.contains(phone) { return 0.45 }
            return 1
        }

        fileprivate static func distance(_ left: [Character], _ right: [Character]) -> Double {
            var previous = Array(repeating: 0.0, count: right.count + 1)
            if !right.isEmpty {
                for index in 1...right.count {
                    previous[index] = previous[index - 1] + indelCost(right[index - 1])
                }
            }

            for leftIndex in left.indices {
                var current = Array(repeating: 0.0, count: right.count + 1)
                current[0] = previous[0] + indelCost(left[leftIndex])
                if !right.isEmpty {
                    for rightIndex in right.indices {
                        current[rightIndex + 1] = min(
                            previous[rightIndex + 1] + indelCost(left[leftIndex]),
                            min(
                                current[rightIndex] + indelCost(right[rightIndex]),
                                previous[rightIndex] + substitutionCost(left[leftIndex], right[rightIndex])
                            )
                        )
                    }
                }
                previous = current
            }

            let weightedCount = (left.count >= right.count ? left : right)
                .reduce(0.0) { $0 + (vowels.contains($1) ? 0.5 : 1) }
            return previous[right.count] / max(1, weightedCount)
        }
    }

    private struct Decision {
        enum Kind { case keep, hindi, english, ambiguous }
        var kind: Kind
        var word: String
        var prefix: String
        var suffix: String
        var englishIndex: Int?
        var ambiguousEnglish: String?
    }

    private static let bundledLexicon = Bundle.main.url(
        forResource: "NemotronEnglishPronunciations",
        withExtension: "txt"
    ).flatMap(Lexicon.init(url:))

    private static let ambiguousWords = ["इस": "is", "सो": "so", "आई": "I", "बट": "but"]

    private static let hindiWords: Set<String> = {
        var words = Set("""
        है हैं हूं हूँ हो था थी थे में मैं मे का की के को से पर और नहीं ना न तो ये वो यह वह कि भी कुछ मुझे मेरा मेरी मेरे
        हम हमें हमारा आप आपका तुम तुम्हारा क्या कोई ही जो लिए रहा रही रहे करना करो करता करती करते कर किया की बहुत अगर
        लेकिन तक अब बीच बोल बोला बोली बोलना बोलता बोलती देता देती देना दे दो दिया लेना ले लो लिया जाना जा जाता जाती गया
        गई गए आना आ आता आती आया आई आए चाहिए चाहता चाहती चाहते सकता सकती सकते होगा होगी होता होती हुआ हुई वाला वाली
        वाले नाम कैसे कैसा कब कहाँ कहां क्यों क्यूं यहाँ यहां वहाँ वहां सब सारा थोड़ा ज़्यादा ज्यादा अच्छा अच्छी ठीक हाँ हां
        जी भाई यार मतलब बस फिर उसको उसका उसकी उसे इसको इसका इसकी इसे उनको उनका इन उन जब तब ऐसा ऐसे वैसे जैसे
        मुझको तुझे अपना अपनी अपने दिन रात आज कल अभी पहले बाद साथ बात काम घर लोग देखो देख देखा सुनो सुन पता
        लगता लगती लगा मिल मिला मिलेगा हिंदी हिन्दी शायद सही गलत ग़लत पूरा पूरी नया नई पुराना बड़ा छोटा कितना कितने
        """.split(whereSeparator: \.isWhitespace).map(String.init))
        words.formUnion("""
        बना बनाना बनाया बनेगा देगा देगी देंगे दूंगा दूँगा लूंगा उतना जितना इतना सकता सकती भेजा भेज भर भरा समझा समझ समझे
        करेगा करेगी करेंगे होगा रहेगा चल चलो चला मान माना सोच सोचा पूछ पूछा बता बताओ बताया लगेगा चीज़ चीज ज़रूरत जरूरत
        तेरा तेरी तेरे तेरे तू तूने मैंने उसने हमने आपने उसको इनको किसी किस कौन कोई दोनों एक दो तीन चार पांच
        """.split(whereSeparator: \.isWhitespace).map(String.init))
        words.subtract(ambiguousWords.keys)
        return words
    }()

    /// Returns the original text when either decode cannot provide alignment evidence.
    static func restore(
        autoText: String,
        autoWords: [TimedWord],
        englishWords: [TimedWord],
        lexicon: Lexicon? = nil
    ) -> String {
        guard !autoText.isEmpty,
              containsDevanagari(autoText),
              !autoWords.isEmpty,
              !englishWords.isEmpty
        else { return autoText }

        // Almost no real Hindi in the line: it was English heard as Hindi, so the English decode is the transcript.
        let knownHindiCount = autoWords.filter { hindiWords.contains(splitPunctuation($0.text).core) }.count
        if Double(knownHindiCount) / Double(autoWords.count) < 0.05 {
            return englishWords.map(\.text).joined(separator: " ")
        }

        let pronunciationLexicon = lexicon ?? bundledLexicon
        var decisions: [Decision] = []
        var phoneCache: [String: [Character]] = [:]
        var dictionaryCache: [String: (String?, Double)] = [:]
        var skipNext = false

        for index in autoWords.indices {
            if skipNext {
                skipNext = false
                continue
            }

            let word = autoWords[index]
            let (prefix, core, initialSuffix) = splitPunctuation(word.text)
            var suffix = initialSuffix
            guard containsDevanagari(core) else {
                decisions.append(Decision(kind: .keep, word: word.text, prefix: "", suffix: "", englishIndex: nil, ambiguousEnglish: nil))
                continue
            }
            guard !hindiWords.contains(core) else {
                decisions.append(Decision(kind: .hindi, word: core, prefix: prefix, suffix: suffix, englishIndex: nil, ambiguousEnglish: nil))
                continue
            }

            let phones = phoneCache[core] ?? devanagariPhones(core)
            phoneCache[core] = phones
            var choice: String?
            var usedEnglishIndex: Int?
            if !phones.isEmpty {
                var best: (word: String, distance: Double, index: Int, merged: Bool)?
                for englishIndex in englishWords.indices {
                    let english = englishWords[englishIndex]
                    guard english.start < word.end + 0.25,
                          english.end > word.start - 0.25
                    else { continue }

                    let candidate = englishSpellingCore(english.text)
                    let lookupWord = candidate.lowercased()
                    guard let pronunciations = pronunciationLexicon?.pronunciations(for: lookupWord),
                          !pronunciations.isEmpty
                    else { continue }

                    var distance = pronunciations.map { Lexicon.distance(phones, $0) }.min() ?? 9
                    var merged = false
                    if index + 1 < autoWords.count {
                        let nextWord = autoWords[index + 1]
                        let (_, nextCore, _) = splitPunctuation(nextWord.text)
                        if containsDevanagari(nextCore), !hindiWords.contains(nextCore),
                           word.start < english.end, word.end > english.start,
                           nextWord.start < english.end, nextWord.end > english.start {
                            let mergedDistance = pronunciations
                                .map { Lexicon.distance(phones + devanagariPhones(nextCore), $0) }
                                .min() ?? 9
                            if mergedDistance < distance {
                                distance = mergedDistance
                                merged = true
                            }
                        }
                    }

                    if best == nil || distance < best!.distance {
                        best = (candidate, distance, englishIndex, merged)
                    }
                }

                if let best, best.distance <= 0.32 {
                    choice = best.word
                    usedEnglishIndex = best.index
                    if best.merged {
                        skipNext = true
                        suffix = splitPunctuation(autoWords[index + 1].text).suffix
                    }
                }
            }

            if choice == nil, let pronunciationLexicon {
                let result: (String?, Double)
                if let cached = dictionaryCache[core] {
                    result = cached
                } else {
                    result = pronunciationLexicon.closestWord(to: phones)
                    dictionaryCache[core] = result
                }
                let (dictionaryWord, distance) = result
                if let dictionaryWord, distance <= 0.2 {
                    choice = dictionaryWord == "i" ? "I" : dictionaryWord
                }
            }

            if ambiguousWords[core] != nil {
                decisions.append(Decision(
                    kind: .ambiguous,
                    word: core,
                    prefix: prefix,
                    suffix: suffix,
                    englishIndex: usedEnglishIndex,
                    ambiguousEnglish: usedEnglishIndex == nil ? ambiguousWords[core] : choice
                ))
            } else if let choice {
                decisions.append(Decision(kind: .english, word: choice, prefix: prefix, suffix: suffix, englishIndex: usedEnglishIndex, ambiguousEnglish: nil))
            } else {
                decisions.append(Decision(kind: .hindi, word: core, prefix: prefix, suffix: suffix, englishIndex: nil, ambiguousEnglish: nil))
            }
        }

        for index in decisions.indices where decisions[index].kind == .ambiguous {
            var votes = 0
            for neighbor in max(0, index - 2)..<index {
                votes += languageVote(for: decisions[neighbor].kind)
            }
            if index + 1 < decisions.count {
                for neighbor in (index + 1)..<min(decisions.count, index + 3) {
                    votes += languageVote(for: decisions[neighbor].kind)
                }
            }
            if votes > 0 {
                decisions[index].kind = .english
                decisions[index].word = decisions[index].ambiguousEnglish ?? decisions[index].word
            } else {
                decisions[index].kind = .hindi
            }
        }

        var output: [String] = []
        var lastEnglishIndex: Int?
        for decision in decisions {
            if decision.kind == .english, let englishIndex = decision.englishIndex,
               englishIndex == lastEnglishIndex {
                continue
            }
            lastEnglishIndex = decision.kind == .english ? decision.englishIndex : nil

            switch decision.kind {
            case .keep:
                output.append(decision.word)
            case .english:
                output.append(decision.prefix + decision.word + normalizePunctuation(decision.suffix))
            case .ambiguous:
                let word = decision.ambiguousEnglish ?? decision.word
                output.append(decision.prefix + word + normalizePunctuation(decision.suffix))
            case .hindi:
                output.append(decision.prefix + HinglishRomanizer.romanize(decision.word) + normalizePunctuation(decision.suffix))
            }
        }
        return output.joined(separator: " ")
    }

    private static func languageVote(for kind: Decision.Kind) -> Int {
        switch kind {
        case .hindi: return -1
        case .english, .keep: return 1
        case .ambiguous: return 0
        }
    }

    static func containsDevanagari(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x0900...0x097F).contains(scalar.value)
                || CharacterSet.alphanumerics.contains(scalar)
                || scalar == "_"
        }
    }

    private static func splitPunctuation(_ word: String) -> (prefix: String, core: String, suffix: String) {
        let characters = Array(word)
        var start = 0
        var end = characters.count
        while start < end, !isWordCharacter(characters[start]) { start += 1 }
        while end > start, !isWordCharacter(characters[end - 1]) { end -= 1 }
        return (
            String(characters[..<start]),
            String(characters[start..<end]),
            String(characters[end...])
        )
    }

    private static func englishSpellingCore(_ text: String) -> String {
        String(text.filter { isWordCharacter($0) || $0 == "'" })
    }

    private static func normalizePunctuation(_ suffix: String) -> String {
        suffix.replacingOccurrences(of: "।", with: ".")
    }

    private static func devanagariPhones(_ word: String) -> [Character] {
        let scalars = Array(word.unicodeScalars)
        var output: [Character] = []
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            let value = scalar.value
            if let consonant = consonants[value] {
                var sound = consonant
                index += 1
                if index < scalars.count, scalars[index].value == 0x093C {
                    sound = nukta[consonant] ?? consonant
                    index += 1
                }
                output.append(contentsOf: sound)
                if index < scalars.count, scalars[index].value == 0x094D {
                    index += 1
                } else if index < scalars.count, let vowel = matras[scalars[index].value] {
                    output.append(contentsOf: vowel)
                    index += 1
                } else {
                    output.append("ə")
                }
            } else if let vowel = independentVowels[value] {
                output.append(contentsOf: vowel)
                index += 1
            } else if value == 0x0902 || value == 0x0901 {
                output.append("N")
                index += 1
            } else {
                index += 1
            }
        }

        if output.last == "ə" { output.removeLast() }
        return output
    }

    private static let consonants: [UInt32: String] = [
        0x0915: "k", 0x0916: "k", 0x0917: "g", 0x0918: "g", 0x0919: "n", 0x091A: "c", 0x091B: "c", 0x091C: "j", 0x091D: "j", 0x091E: "n",
        0x091F: "t", 0x0920: "t", 0x0921: "d", 0x0922: "d", 0x0923: "n", 0x0924: "t", 0x0925: "t", 0x0926: "d", 0x0927: "d", 0x0928: "n",
        0x092A: "p", 0x092B: "f", 0x092C: "b", 0x092D: "b", 0x092E: "m", 0x092F: "y", 0x0930: "r", 0x0931: "r", 0x0932: "l", 0x0933: "l", 0x0935: "v",
        0x0936: "S", 0x0937: "S", 0x0938: "s", 0x0939: "h", 0x0958: "k", 0x0959: "k", 0x095A: "g", 0x095B: "z", 0x095C: "r", 0x095D: "r", 0x095E: "f", 0x095F: "y",
    ]

    private static let nukta: [String: String] = ["k": "k", "g": "g", "j": "z", "d": "r", "ph": "f"]
    private static let matras: [UInt32: String] = [
        0x093E: "a", 0x093F: "i", 0x0940: "i", 0x0941: "u", 0x0942: "u", 0x0947: "e", 0x0948: "e",
        0x094B: "o", 0x094C: "O", 0x0943: "ri", 0x0945: "e", 0x0949: "O",
    ]
    private static let independentVowels: [UInt32: String] = [
        0x0905: "a", 0x0906: "a", 0x0907: "i", 0x0908: "i", 0x0909: "u", 0x090A: "u", 0x090B: "ri",
        0x090D: "e", 0x090F: "e", 0x0910: "e", 0x0911: "O", 0x0913: "o", 0x0914: "O",
    ]
}
