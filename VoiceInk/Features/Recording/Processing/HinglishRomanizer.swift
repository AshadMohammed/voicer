import Foundation

/// Spells Devanagari words in Roman letters the way Hinglish is typed ("मेरा नाम है" becomes "mera naam hai").
/// Latin text, digits and punctuation pass through untouched, so a mixed line keeps its English words.
/// English words the model wrote in Devanagari come out as their sound ("टेस्टिंग" becomes "testing").
enum HinglishRomanizer {
    static func romanize(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isDevanagari) else { return text }

        var output = ""
        var word: [Unicode.Scalar] = []

        func flushWord() {
            if !word.isEmpty {
                output += romanizeWord(word)
                word.removeAll()
            }
        }

        for scalar in text.unicodeScalars {
            if isDevanagari(scalar) && scalar != "\u{0964}" && scalar != "\u{0965}" {
                word.append(scalar)
            } else {
                flushWord()
                if scalar == "\u{0964}" || scalar == "\u{0965}" {
                    output += "."
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        flushWord()
        return output
    }

    private static func isDevanagari(_ scalar: Unicode.Scalar) -> Bool {
        (0x0900...0x097F).contains(scalar.value)
    }

    private struct Unit {
        var consonant: String?
        var vowel: String?
        var halant = false
        var nasal = false
        var visarga = false
        var matra: Unicode.Scalar?
        var inherent: Bool { consonant != nil && vowel == nil && !halant }
        var labialNext = false
    }

    private static let consonants: [UInt32: String] = [
        0x0915: "k", 0x0916: "kh", 0x0917: "g", 0x0918: "gh", 0x0919: "n",
        0x091A: "ch", 0x091B: "chh", 0x091C: "j", 0x091D: "jh", 0x091E: "n",
        0x091F: "t", 0x0920: "th", 0x0921: "d", 0x0922: "dh", 0x0923: "n",
        0x0924: "t", 0x0925: "th", 0x0926: "d", 0x0927: "dh", 0x0928: "n",
        0x092A: "p", 0x092B: "ph", 0x092C: "b", 0x092D: "bh", 0x092E: "m",
        0x092F: "y", 0x0930: "r", 0x0931: "r", 0x0932: "l", 0x0933: "l", 0x0935: "v",
        0x0936: "sh", 0x0937: "sh", 0x0938: "s", 0x0939: "h",
        0x0958: "q", 0x0959: "kh", 0x095A: "gh", 0x095B: "z", 0x095C: "r", 0x095D: "rh", 0x095E: "f", 0x095F: "y",
    ]

    private static let nuktaForms: [String: String] = [
        "k": "q", "kh": "kh", "g": "gh", "j": "z", "d": "r", "dh": "rh", "ph": "f",
    ]

    private static let independentVowels: [UInt32: String] = [
        0x0905: "a", 0x0906: "aa", 0x0907: "i", 0x0908: "ee", 0x0909: "u", 0x090A: "oo", 0x090B: "ri",
        0x090D: "e", 0x090F: "e", 0x0910: "ai", 0x0911: "o", 0x0913: "o", 0x0914: "au",
    ]

    private static let matras: [UInt32: String] = [
        0x093E: "aa", 0x093F: "i", 0x0940: "ee", 0x0941: "u", 0x0942: "oo", 0x0943: "ri",
        0x0945: "e", 0x0947: "e", 0x0948: "ai", 0x0949: "o", 0x094B: "o", 0x094C: "au",
    ]

    private static func romanizeWord(_ scalars: [Unicode.Scalar]) -> String {
        var units: [Unit] = []
        var i = 0
        while i < scalars.count {
            let v = scalars[i].value
            if var base = consonants[v] {
                i += 1
                if i < scalars.count, scalars[i].value == 0x093C {
                    base = nuktaForms[base] ?? base
                    i += 1
                }
                var unit = Unit(consonant: base)
                if i < scalars.count, scalars[i].value == 0x094D {
                    unit.halant = true
                    i += 1
                } else if i < scalars.count, let m = matras[scalars[i].value] {
                    unit.vowel = m
                    unit.matra = scalars[i]
                    i += 1
                }
                units.append(unit)
            } else if let vowel = independentVowels[v] {
                var unit = Unit(vowel: vowel)
                if v == 0x0908 && !units.isEmpty { unit.vowel = "i" }
                units.append(unit)
                i += 1
            } else if v == 0x0902 || v == 0x0901 {
                if !units.isEmpty { units[units.count - 1].nasal = true }
                i += 1
            } else if v == 0x0903 {
                if !units.isEmpty { units[units.count - 1].visarga = true }
                i += 1
            } else if (0x0966...0x096F).contains(v) {
                units.append(Unit(vowel: String(v - 0x0966)))
                units[units.count - 1].consonant = ""
                units[units.count - 1].vowel = String(v - 0x0966)
                i += 1
            } else {
                i += 1
            }
        }

        // Which units start with a labial, so a nasal before it is spelled "m".
        for index in units.indices.dropLast() {
            if let c = units[index + 1].consonant, ["p", "ph", "b", "bh", "m"].contains(c) {
                units[index].labialNext = true
            }
        }

        // Drop the silent "a": at the end of a word, and inside it when it sits between two sounded syllables.
        var deleted = Array(repeating: false, count: units.count)
        let last = units.count - 1
        if last > 0, units[last].inherent { deleted[last] = true }
        func sounded(_ index: Int) -> Bool {
            let unit = units[index]
            if unit.halant { return false }
            if unit.inherent { return !deleted[index] }
            return true
        }
        if last > 1 {
            for index in stride(from: last - 1, through: 1, by: -1) where units[index].inherent {
                if sounded(index - 1) && sounded(index + 1) { deleted[index] = true }
            }
        }

        var result = ""
        for (index, unit) in units.enumerated() {
            let isFinal = index == last
            var text = unit.consonant ?? ""
            if unit.halant {
                // consonant cluster, no vowel
            } else if var vowel = unit.vowel {
                if unit.consonant == "" {
                    // digit
                } else {
                    if isFinal && !unit.nasal {
                        switch vowel {
                        case "aa": vowel = "a"
                        case "ee": vowel = "i"
                        case "oo": vowel = "u"
                        default: break
                        }
                    }
                    if unit.nasal {
                        switch vowel {
                        case "e": vowel = "ei"
                        case "ee": vowel = "i"
                        default: break
                        }
                    }
                }
                text += vowel
            } else if unit.consonant != nil && !deleted[index] {
                text += "a"
            }
            if unit.nasal {
                text += unit.labialNext ? "m" : "n"
            }
            if unit.visarga { text += "h" }
            result += text
        }
        return result
    }
}
