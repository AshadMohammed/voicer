import SwiftUI

struct AudioVisualizer: View {
    let audioMeterProvider: () -> AudioMeter
    let color: Color
    let isActive: Bool

    private let barCount = 15
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let minHeight: CGFloat = 4
    private let maxHeight: CGFloat = 28

    @State private var levels = VoiceLevelHistory(size: 8)

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.016)) { context in
            let history = levels.update(with: audioMeterProvider(), at: context.date)

            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(color.opacity(0.85))
                        .frame(width: barWidth, height: barHeight(for: index, history: history))
                }
            }
        }
    }

    // The middle bar shows the voice level right now and older levels spread outward,
    // so the bars sit flat in silence and only move when you speak.
    private func barHeight(for index: Int, history: [Double]) -> CGFloat {
        guard isActive else { return minHeight }

        let center = barCount / 2
        let age = abs(index - center)
        let level = age < history.count ? history[age] : 0
        let centerBoost = 1.0 - Double(age) / Double(center) * 0.4

        return minHeight + CGFloat(level * centerBoost) * (maxHeight - minHeight)
    }
}

/// Turns the mic level into a voice level by learning the room's background noise and showing only sound above it.
final class VoiceLevelHistory {
    // Levels use the recorder's 0...1 scale, where 1.0 spans 60 dB.
    private static var noiseFloor = 1.0 / 6.0  // about -50 dB until the room is heard; remembered between recordings
    private let floorRisePerSecond = 5.0 / 60.0  // 5 dB a second, so a steady hum is learned but a sentence isn't
    private let gateMargin = 6.0 / 60.0  // sound must clear the room noise by 6 dB to count as voice
    private let fullScale = 24.0 / 60.0  // 24 dB past the gate fills the bar
    private let shiftInterval: TimeInterval = 0.06

    private var samples: [Double]
    private var lastFrame: Date?
    private var firstHeard: Date?
    private var lastShift = Date.distantPast

    init(size: Int) {
        samples = Array(repeating: 0, count: size)
    }

    func update(with meter: AudioMeter, at date: Date) -> [Double] {
        let level = meter.averagePower
        let elapsed = lastFrame.map { min(max(date.timeIntervalSince($0), 0), 0.1) } ?? 0
        lastFrame = date

        // The floor drops at once to any quieter moment and creeps up slowly, so it settles on the room's steady noise.
        // The mic reads silent and then fades in as a recording starts, so the floor waits until that has settled.
        if firstHeard == nil, level > 0.01 { firstHeard = date }
        if let firstHeard, date.timeIntervalSince(firstHeard) > 0.15 {
            Self.noiseFloor = min(level, Self.noiseFloor + elapsed * floorRisePerSecond)
        }

        let aboveGate = (level - Self.noiseFloor - gateMargin) / fullScale
        let voice = pow(max(0, min(1, aboveGate)), 0.8)

        if date.timeIntervalSince(lastShift) >= shiftInterval {
            samples.insert(voice, at: 0)
            samples.removeLast()
            lastShift = date
        } else {
            samples[0] = voice
        }
        return samples
    }
}

// Flat bars shown when the recorder is idle (no audio input)
struct StaticVisualizer: View {
    private let barCount = 15
    private let barWidth: CGFloat = 3
    private let barHeight: CGFloat = 4
    private let barSpacing: CGFloat = 2
    let color: Color

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { _ in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color.opacity(0.5))
                    .frame(width: barWidth, height: barHeight)
            }
        }
    }
}

// MARK: - Processing Status Display

struct ProcessingStatusDisplay: View {
    enum Mode {
        case transcribing
        case enhancing
    }

    let mode: Mode
    let color: Color

    private var label: LocalizedStringKey {
        switch mode {
        case .transcribing: return "Transcribing"
        case .enhancing: return "Enhancing"
        }
    }

    private var animationSpeed: Double {
        switch mode {
        case .transcribing: return 0.18
        case .enhancing: return 0.22
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .foregroundColor(color)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            ProgressAnimation(color: color, animationSpeed: animationSpeed)
        }
        .frame(height: 28)  // matches AudioVisualizer maxHeight to prevent layout shift
    }
}
