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
    static func compress(_ url: URL) async -> URL {
        let asset = AVURLAsset(url: url)
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
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // Non-fatal: we have the compressed file; log and move on.
            logger.warning("Could not delete original after export: \(error.localizedDescription, privacy: .public)")
        }

        return outputURL
    }
}

