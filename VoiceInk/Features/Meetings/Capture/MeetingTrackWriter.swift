import AVFoundation
import Foundation
import os

/// Hands audio from a capture thread to the current writer. The writer is swapped on the main actor while
/// capture callbacks may still be running, so the reference is guarded by a lock.
final class MeetingTrackSink: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: MeetingTrackWriter?

    func set(_ writer: MeetingTrackWriter?) {
        lock.lock()
        self.writer = writer
        lock.unlock()
    }

    private var currentWriter: MeetingTrackWriter? {
        lock.lock()
        defer { lock.unlock() }
        return writer
    }

    func enqueue(_ samples: [Float], sampleRate: Double, hostTime: UInt64) {
        currentWriter?.enqueue(samples, sampleRate: sampleRate, hostTime: hostTime)
    }

    var level: Float {
        currentWriter?.level ?? 0
    }
}

final class MeetingTrackWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let logger: Logger
    private let onProblem: @Sendable (String) -> Void
    private let sessionHostTime: UInt64
    private let timebase: mach_timebase_info_data_t
    let sampleRate: Double
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let levelLock = NSLock()
    private var recentLevel: Float = 0
    private var writtenFrames: AVAudioFramePosition = 0
    private var receivedFrames: AVAudioFramePosition = 0
    private var converter: AVAudioConverter?
    private var converterInputRate: Double = 0
    private var closed = false
    private var firstTimedBuffer = true
    private var firstWriteError: String?
    private var failedWriteCount = 0

    var level: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return recentLevel
    }

    var frameCount: AVAudioFramePosition {
        queue.sync { writtenFrames }
    }

    var problem: String? {
        queue.sync {
            guard let firstWriteError else { return nil }
            return "Audio writing failed \(failedWriteCount) time(s): \(firstWriteError)"
        }
    }

    init(url: URL, sampleRate: Double, sessionHostTime: UInt64, label: String,
         onProblem: @escaping @Sendable (String) -> Void = { _ in }) throws {
        self.sessionHostTime = sessionHostTime
        self.onProblem = onProblem
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        self.timebase = timebase
        self.sampleRate = sampleRate
        self.queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.meeting.writer.\(label)")
        self.logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCapture")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false) else {
            throw WriterError.invalidFormat
        }
        self.format = format
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        self.file = try AVAudioFile(forWriting: url, settings: settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func enqueue(_ samples: [Float], sampleRate: Double, hostTime: UInt64) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            self?.append(samples, sampleRate: sampleRate, hostTime: hostTime)
        }
    }

    func finish() {
        queue.sync {
            guard !closed else { return }
            closed = true
            file.close()
        }
    }

    private func append(_ samples: [Float], sampleRate: Double, hostTime: UInt64) {
        guard !closed else { return }
        do {
            guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                                  channels: 1, interleaved: false),
                  let input = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                               frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = input.floatChannelData?.pointee else { throw WriterError.invalidFormat }
            input.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: samples.count)
            }

            let output: AVAudioPCMBuffer
            if abs(sampleRate - format.sampleRate) < 0.5 {
                output = input
            } else {
                if converter == nil || converterInputRate != sampleRate {
                    guard let newConverter = AVAudioConverter(from: inputFormat, to: format) else {
                        throw WriterError.converterUnavailable
                    }
                    converter = newConverter
                    converterInputRate = sampleRate
                }
                guard let converter,
                      let converted = AVAudioPCMBuffer(
                        pcmFormat: format,
                        frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * format.sampleRate / sampleRate) + 32)
                      ) else { throw WriterError.converterUnavailable }
                var supplied = false
                var conversionError: NSError?
                let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
                    if supplied {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    supplied = true
                    outStatus.pointee = .haveData
                    return input
                }
                if status == .error { throw conversionError ?? WriterError.conversionFailed }
                output = converted
            }

            var bufferToWrite = output
            if hostTime != 0 {
                let target = targetFrame(hostTime: hostTime)
                let drift = target - writtenFrames
                if firstTimedBuffer {
                    if drift > 0 { try writeSilence(frames: drift) }
                    firstTimedBuffer = false
                } else {
                    let threshold = AVAudioFramePosition(format.sampleRate * 0.1)
                    if drift > threshold {
                        try writeSilence(frames: drift)
                    } else if drift < -threshold {
                        let trim = min(-drift, AVAudioFramePosition(output.frameLength))
                        bufferToWrite = try droppingLeadingFrames(Int(trim), from: output)
                    }
                }
            }
            let frames = AVAudioFramePosition(bufferToWrite.frameLength)
            if frames > 0 { try file.write(from: bufferToWrite) }
            writtenFrames += frames
            receivedFrames += AVAudioFramePosition(samples.count)
            if let data = output.floatChannelData?.pointee, output.frameLength > 0 {
                var peak: Float = 0
                for index in 0..<Int(output.frameLength) { peak = max(peak, abs(data[index])) }
                levelLock.lock()
                recentLevel = min(1, peak)
                levelLock.unlock()
            }
        } catch {
            failedWriteCount += 1
            if firstWriteError == nil {
                firstWriteError = error.localizedDescription
                onProblem("Meeting audio could not be saved (\(error.localizedDescription)).")
            }
            logger.error("Meeting track write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func droppingLeadingFrames(_ count: Int, from source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let remaining = Int(source.frameLength) - count
        guard remaining >= 0,
              let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, remaining))),
              let input = source.floatChannelData?.pointee,
              let output = result.floatChannelData?.pointee else { throw WriterError.invalidFormat }
        result.frameLength = AVAudioFrameCount(remaining)
        if remaining > 0 { output.update(from: input.advanced(by: count), count: remaining) }
        return result
    }

    private func targetFrame(hostTime: UInt64) -> AVAudioFramePosition {
        guard hostTime > sessionHostTime else { return 0 }
        let ticks = hostTime - sessionHostTime
        let nanos = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
        return AVAudioFramePosition(nanos / 1_000_000_000 * format.sampleRate)
    }

    private func writeSilence(frames: AVAudioFramePosition) throws {
        guard frames > 0 else { return }
        let chunkLimit: AVAudioFrameCount = 32_768
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkLimit),
              let samples = silence.floatChannelData?.pointee else { throw WriterError.invalidFormat }
        samples.initialize(repeating: 0, count: Int(chunkLimit))
        var remaining = frames
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(chunkLimit)))
            silence.frameLength = count
            try file.write(from: silence)
            writtenFrames += AVAudioFramePosition(count)
            remaining -= AVAudioFramePosition(count)
        }
    }

    private enum WriterError: LocalizedError {
        case invalidFormat, converterUnavailable, conversionFailed
        var errorDescription: String? {
            switch self {
            case .invalidFormat: "The audio format is unsupported."
            case .converterUnavailable: "The sample-rate converter could not be created."
            case .conversionFailed: "Audio sample-rate conversion failed."
            }
        }
    }
}
