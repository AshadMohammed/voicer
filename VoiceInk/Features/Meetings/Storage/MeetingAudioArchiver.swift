import AVFoundation
import os

enum MeetingAudioArchiver {
    private static let logger = Logger(
        subsystem: "com.ashadmohammed.voicer",
        category: "MeetingStorage"
    )

    /// Converts `url` (any CAF/PCM file) to a small AAC `.m4a` in the same folder.
    /// Deletes the original only when export succeeds.
    /// - Returns: The `.m4a` URL on success, or the original URL on any failure.
    static func compress(_ url: URL, deleteOriginal: Bool = true) async -> URL {
        let readableURL: URL
        do {
            readableURL = try CAFRecoveryReader.repairedCopyIfNeeded(of: url) ?? url
        } catch {
            logger.error("Could not repair \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return url
        }
        defer {
            if readableURL != url { try? FileManager.default.removeItem(at: readableURL) }
        }
        let asset = AVURLAsset(url: readableURL)
        let outputURL = url.deletingPathExtension().appendingPathExtension("m4a")

        // If an m4a already exists (a previous run partially succeeded), remove it first.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            do {
                try FileManager.default.removeItem(at: outputURL)
            } catch {
                logger.error("Could not remove existing m4a before re-export: \(error.localizedDescription, privacy: .public)")
                return url
            }
        }

        do {
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                logger.error("No AAC exporter for \(url.lastPathComponent, privacy: .public)")
                return url
            }
            try await session.export(to: outputURL, as: .m4a)
        } catch {
            logger.error("AAC export failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Clean up any partial output.
            try? FileManager.default.removeItem(at: outputURL)
            return url
        }

        // Remove the original only after a confirmed successful export.
        if deleteOriginal {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
            // Non-fatal: we have the compressed file; log and move on.
                logger.warning("Could not delete original after export: \(error.localizedDescription, privacy: .public)")
            }
        }

        return outputURL
    }

    /// Mixes the microphone ("You") and call ("Speaker") tracks into one AAC `.m4a`, both audible. The tracks are
    /// left untouched. Either track may be missing; with one, the file is that track alone.
    /// - Returns: true when `outputURL` was written.
    static func mixdown(microphone: URL?, call: URL?, to outputURL: URL) async -> Bool {
        let composition = AVMutableComposition()
        var insertedTracks = 0

        var repairedCopies: [URL] = []
        defer { repairedCopies.forEach { try? FileManager.default.removeItem(at: $0) } }
        for url in [microphone, call].compactMap({ $0 }) {
            let readableURL: URL
            do {
                if let repaired = try CAFRecoveryReader.repairedCopyIfNeeded(of: url) {
                    repairedCopies.append(repaired)
                    readableURL = repaired
                } else {
                    readableURL = url
                }
            } catch {
                logger.error("Could not repair \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            let asset = AVURLAsset(url: readableURL)
            guard
                let source = try? await asset.loadTracks(withMediaType: .audio).first,
                let duration = try? await asset.load(.duration),
                duration.seconds > 0,
                let track = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            do {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
                insertedTracks += 1
            } catch {
                logger.error("Could not add \(url.lastPathComponent, privacy: .public) to the mix: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard insertedTracks > 0 else { return false }

        try? FileManager.default.removeItem(at: outputURL)
        do {
            guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
                logger.error("No AAC exporter for the meeting mix")
                return false
            }
            try await session.export(to: outputURL, as: .m4a)
            return true
        } catch {
            logger.error("Meeting mix export failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }
    }
}
