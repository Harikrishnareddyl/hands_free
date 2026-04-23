import AVFoundation
import Foundation

enum AudioCueMode: String, Codable, CaseIterable {
    case off
    case chimesOnly
    case all

    var label: String {
        switch self {
        case .off:        return "Off"
        case .chimesOnly: return "Start / end chimes only"
        case .all:        return "Chimes + processing tick"
        }
    }
}

/// Synthesized audio cues:
/// - `playStart` / `playEnd`: a single soft bell tone (fundamental + a quiet
///   octave for warmth). Start is higher pitched than end so the pair has
///   a natural "open / close" feel without sounding like a melody.
/// - `startHum` / `stopHum`: a quiet sustained tone with subtle tremolo,
///   played on a separate node so it doesn't compete with the chimes.
@MainActor
enum SoundEffects {
    private static let engine = AVAudioEngine()
    private static let chimeNode = AVAudioPlayerNode()
    private static let humNode = AVAudioPlayerNode()
    private static var started = false

    private static let sampleRate: Double = 44_100

    // Tone choices — start = A5 (880Hz), end = E5 (659.25Hz). Pleasant interval (a 4th).
    private static let startFreq: Double = 880.0
    private static let endFreq: Double   = 659.25
    // "Thinking" tick — G6 (≈1568 Hz), clearly higher register than the chimes
    // so it reads as a tick rather than a small version of the end chime.
    private static let tickFreq: Double  = 1567.98
    // Countdown tick — a step higher (A6 ≈ 1760 Hz) and noticeably louder than
    // the processing tick, so the final-seconds warning stands out without
    // clashing with any bell already in flight.
    private static let countdownFreq: Double = 1760.0

    // Volume levels. AVAudioEngine output is in [-1, 1] linear amplitude.
    private static let chimeVolume: Float = 0.10   // ≈ -20 dBFS — present but not startling
    private static let tickVolume: Float  = 0.015  // ≈ -36 dBFS — barely there, just a pulse
    private static let countdownVolume: Float = 0.06  // ≈ -24 dBFS — ~4× louder than the processing tick

    static func playStart() {
        guard ensureStarted() else { return }
        chimeNode.scheduleBuffer(bellBuffer(fundamental: startFreq), at: nil, options: .interrupts)
    }

    static func playEnd() {
        guard ensureStarted() else { return }
        chimeNode.scheduleBuffer(bellBuffer(fundamental: endFreq), at: nil, options: .interrupts)
    }

    /// One-shot countdown pulse for the final-5-seconds warning. Higher and
    /// louder than the processing tick so it reads as "hurry up" rather than
    /// "still thinking".
    static func playCountdownTick() {
        guard ensureStarted() else { return }
        chimeNode.scheduleBuffer(countdownTickBuffer(), at: nil, options: [])
    }

    /// Starts a quiet periodic "tick" loop — a tiny soft chime every ~1.5 s —
    /// that signals "something is happening" without the mid-range drone of a hum.
    static func startHum() {
        guard ensureStarted() else { return }
        if humNode.isPlaying { return }
        humNode.scheduleBuffer(tickLoopBuffer(), at: nil, options: .loops)
        humNode.play()
        Log.info("sound", "tick loop started")
    }

    static func stopHum() {
        guard started else { return }
        if humNode.isPlaying {
            humNode.stop()
            Log.info("sound", "tick loop stopped")
        }
    }

    // MARK: - Engine setup

    @discardableResult
    private static func ensureStarted() -> Bool {
        if started { return true }
        engine.attach(chimeNode)
        engine.attach(humNode)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        engine.connect(chimeNode, to: engine.mainMixerNode, format: format)
        engine.connect(humNode, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            chimeNode.play()
            started = true
            return true
        } catch {
            Log.error("sound", "engine start failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Buffer synthesis

    /// One soft bell tone: fundamental + a mellow octave at low amplitude,
    /// short attack, exponential decay. ~350 ms total — over almost as quickly
    /// as a single key on a glockenspiel.
    private static func bellBuffer(fundamental: Double) -> AVAudioPCMBuffer {
        let duration = 0.35
        let attack = 0.006             // 6 ms attack — soft, no click
        let decayConstant = 0.10       // exp decay; at 0.35s envelope ≈ 3% of peak

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return silentBuffer()
        }
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return silentBuffer()
        }
        buffer.frameLength = frames
        guard let samples = buffer.floatChannelData?[0] else { return buffer }

        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate

            let envelope: Float
            if t < attack {
                envelope = Float(t / attack)
            } else {
                envelope = Float(exp(-(t - attack) / decayConstant))
            }

            // Fundamental + a quiet octave for warmth (avoids the "computer beep" feel
            // of a pure sine without sounding like a complex bell).
            let fund = sin(2 * .pi * fundamental * t)
            let octave = sin(2 * .pi * fundamental * 2.0 * t) * 0.18
            samples[i] = Float(fund + octave) * envelope * chimeVolume
        }
        return buffer
    }

    /// 1.5-second loop containing a single soft 80ms chime followed by silence.
    /// Effect: a quiet "tick … tick … tick …" every 1.5s while processing.
    private static func tickLoopBuffer() -> AVAudioPCMBuffer {
        let loopDuration = 1.5
        let tickDuration = 0.08
        let attack = 0.004
        let decayConstant = 0.025        // quick fade — tick, not a ding

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return silentBuffer()
        }
        let frames = AVAudioFrameCount(sampleRate * loopDuration)
        let tickFrames = Int(sampleRate * tickDuration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return silentBuffer()
        }
        buffer.frameLength = frames
        guard let samples = buffer.floatChannelData?[0] else { return buffer }

        // Fill entire loop with silence first.
        for i in 0..<Int(frames) { samples[i] = 0 }

        // Paint a soft chime at the start.
        for i in 0..<tickFrames {
            let t = Double(i) / sampleRate
            let envelope: Float
            if t < attack {
                envelope = Float(t / attack)
            } else {
                envelope = Float(exp(-(t - attack) / decayConstant))
            }
            let fund = sin(2 * .pi * tickFreq * t)
            let octave = sin(2 * .pi * tickFreq * 2.0 * t) * 0.15
            samples[i] = Float(fund + octave) * envelope * tickVolume
        }
        return buffer
    }

    /// Short one-shot tick used for the final-5-seconds countdown. Same
    /// shape as the processing tick (attack+exp decay) but at `countdownFreq`
    /// and `countdownVolume` so it punches through the ambient sound.
    private static func countdownTickBuffer() -> AVAudioPCMBuffer {
        let duration = 0.10
        let attack = 0.003
        let decayConstant = 0.030

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return silentBuffer()
        }
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return silentBuffer()
        }
        buffer.frameLength = frames
        guard let samples = buffer.floatChannelData?[0] else { return buffer }

        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            let envelope: Float
            if t < attack {
                envelope = Float(t / attack)
            } else {
                envelope = Float(exp(-(t - attack) / decayConstant))
            }
            let fund = sin(2 * .pi * countdownFreq * t)
            let octave = sin(2 * .pi * countdownFreq * 2.0 * t) * 0.12
            samples[i] = Float(fund + octave) * envelope * countdownVolume
        }
        return buffer
    }

    private static func silentBuffer() -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1)!
        buf.frameLength = 1
        return buf
    }
}
