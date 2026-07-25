import AVFoundation
import AppKit

/// The click wheel's tick.
///
/// The original iPod produced this with a piezo buzzer behind the wheel, not a
/// recording — so it is synthesised here rather than sampled. A very short
/// noise transient through a resonant peak gets the character: a dry, plasticky
/// tick with no tail.
@MainActor
final class Clicker {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var isRunning = false

    /// Ticks closer together than this are dropped. Spinning the wheel fast
    /// otherwise queues up a buzz instead of a series of clicks.
    private var lastTick = Date.distantPast
    private static let minimumInterval: TimeInterval = 0.012

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        guard let format else { return }
        buffer = Self.renderTick(format: format)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.35
    }

    /// Starts the audio engine lazily, so an app launch with the clicker
    /// switched off never touches the audio hardware at all.
    private func startIfNeeded() {
        guard !isRunning else { return }
        do {
            try engine.start()
            player.play()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func tick() {
        guard let buffer else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTick) >= Self.minimumInterval else { return }
        lastTick = now

        startIfNeeded()
        guard isRunning else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        isRunning = false
    }

    /// Builds the click waveform once, at init.
    ///
    /// Noise burst with a 1.6 kHz resonance and a ~7 ms exponential decay. The
    /// short window is what makes it read as a mechanical detent rather than a
    /// beep.
    private static func renderTick(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let duration = 0.008
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frames

        // Two-pole resonator excited by noise, which is cheaper and more
        // controllable than filtering afterwards.
        let resonance = 1_600.0
        let omega = 2 * Double.pi * resonance / sampleRate
        var y1 = 0.0
        var y2 = 0.0
        let feedback = 2 * cos(omega) * 0.86
        var seed = UInt64(0x9E37_79B9_7F4A_7C15)

        for frame in 0..<Int(frames) {
            // xorshift keeps the click identical every run; a click that
            // varies audibly between presses sounds like a glitch.
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            let noise = Double(Int64(bitPattern: seed)) / Double(Int64.max)

            let excitation = frame < 3 ? noise : 0
            let sample = excitation + feedback * y1 - 0.74 * y2
            y2 = y1
            y1 = sample

            let envelope = exp(-Double(frame) / (sampleRate * 0.0018))
            channel[frame] = Float(sample * envelope * 0.6)
        }
        return buffer
    }
}

/// Haptic detents through a Force Touch trackpad.
///
/// `NSHapticFeedbackManager` only does anything on hardware that supports it
/// and when the user hasn't disabled it, so this is safe to call unconditionally.
@MainActor
enum Haptics {
    static func detent() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment,
            performanceTime: .now
        )
    }

    static func press() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .levelChange,
            performanceTime: .now
        )
    }
}
