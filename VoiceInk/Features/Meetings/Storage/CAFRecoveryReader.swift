import Foundation

/// Makes a temporary CAF copy with its data chunk length fixed when a crash left the header unfinished.
enum CAFRecoveryReader {
    enum RecoveryError: LocalizedError {
        case invalidCAF
        case missingAudioData

        var errorDescription: String? {
            switch self {
            case .invalidCAF: return "The CAF recording header is invalid."
            case .missingAudioData: return "The CAF recording has no readable audio data."
            }
        }
    }

    /// Returns a repaired temporary copy, or nil when the original header is already complete.
    static func repairedCopyIfNeeded(of url: URL) throws -> URL? {
        guard url.pathExtension.lowercased() == "caf" else { return nil }
        let contents = try Data(contentsOf: url, options: .mappedIfSafe)
        guard contents.count >= 20,
              String(data: contents.prefix(4), encoding: .ascii) == "caff" else {
            throw RecoveryError.invalidCAF
        }

        var offset = 8
        while offset + 12 <= contents.count {
            let chunkID = String(data: contents[offset..<(offset + 4)], encoding: .ascii)
            let declaredSize = contents[(offset + 4)..<(offset + 12)].reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
            let payloadStart = offset + 12
            let available = contents.count - payloadStart

            if chunkID == "data" {
                guard available > 4 else { throw RecoveryError.missingAudioData }
                // Voicer's CAF writer puts audio last, so the file length is authoritative after a crash.
                guard payloadStart + available == contents.count else { throw RecoveryError.invalidCAF }
                guard declaredSize != UInt64(available) else { return nil }

                var repaired = contents
                var correctedSize = UInt64(available).bigEndian
                withUnsafeBytes(of: &correctedSize) { bytes in
                    repaired.replaceSubrange((offset + 4)..<(offset + 12), with: bytes)
                }
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("voicer-recovered-\(UUID().uuidString).caf")
                try repaired.write(to: copy, options: .atomic)
                return copy
            }

            guard declaredSize <= UInt64(available) else { throw RecoveryError.invalidCAF }
            offset = payloadStart + Int(declaredSize)
        }
        throw RecoveryError.missingAudioData
    }
}
