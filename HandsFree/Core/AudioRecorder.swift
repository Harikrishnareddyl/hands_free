import AVFoundation
import Foundation

/// Captures mic audio, downsamples to 16 kHz mono int16 (what Whisper wants)
/// via AVAudioConverter, and streams the int16 frames into a .wav file.
///
/// Upload size drops ~12× compared to writing the native 48 kHz stereo float32
/// format: a 5-second clip is ~160 KB instead of ~1.9 MB.
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case engineFailed(Error)
        case converterFailed

        var errorDescription: String? {
            switch self {
            case .engineFailed(let e): return "Audio engine failed: \(e.localizedDescription)"
            case .converterFailed:     return "Could not create audio converter"
            }
        }
    }

    static let targetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
    }()

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var writer: WAVWriter?
    private var startedAt: Date?

    private(set) var currentURL: URL?
    var isRecording: Bool { engine.isRunning }

    /// Warm up hardware + allocate internal buffers so the first record has
    /// no perceptible latency. Safe to call at app launch.
    func prepareEngine() {
        _ = engine.inputNode.outputFormat(forBus: 0)   // nudges hardware init
        engine.prepare()
        Log.info("audio", "engine pre-warmed")
    }

    func start() throws {
        if engine.isRunning { return }

        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)
        Log.info("audio", "input: \(nativeFormat.sampleRate)Hz/\(nativeFormat.channelCount)ch → target: 16000Hz/1ch int16")

        guard let conv = AVAudioConverter(from: nativeFormat, to: Self.targetFormat) else {
            throw RecorderError.converterFailed
        }
        converter = conv

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("handsfree-\(UUID().uuidString).wav")
        let writer = try WAVWriter(url: url, sampleRate: 16_000, channels: 1)
        self.writer = writer
        self.currentURL = url
        Log.info("audio", "writing to \(url.lastPathComponent)")

        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            self?.convertAndWrite(buffer, nativeFormat: nativeFormat)
        }

        engine.prepare()
        do {
            try engine.start()
            startedAt = Date()
            Log.info("audio", "engine started")
        } catch {
            Log.error("audio", "engine failed to start: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            try? writer.close()
            self.writer = nil
            self.currentURL = nil
            self.converter = nil
            throw RecorderError.engineFailed(error)
        }
    }

    @discardableResult
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard engine.isRunning else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        Task { @MainActor in AudioLevelMonitor.shared.reset() }

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil

        try? writer?.close()
        writer = nil
        converter = nil

        defer { currentURL = nil }
        guard let url = currentURL else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        Log.info("audio", "stopped: \(String(format: "%.2f", duration))s, \(size) bytes")
        return (url, duration)
    }

    // MARK: - Conversion

    private func convertAndWrite(_ input: AVAudioPCMBuffer, nativeFormat: AVAudioFormat) {
        guard let converter = converter, let writer = writer else { return }

        // Rough output frame count based on the sample-rate ratio, plus a small
        // cushion for conversion rounding.
        let ratio = Self.targetFormat.sampleRate / nativeFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(
            pcmFormat: Self.targetFormat,
            frameCapacity: outputFrameCapacity
        ) else { return }

        var error: NSError?
        var delivered = false
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return input
        }

        if let error {
            Log.error("audio", "converter error: \(error.localizedDescription)")
            return
        }
        if output.frameLength == 0 { return }

        try? writer.append(output)
        publishLevel(from: output)
    }

    /// Compute a 0…1 loudness level from the int16 mono buffer and push it to
    /// `AudioLevelMonitor` so the recording pill can react visually. Speech
    /// RMS is typically 0.02…0.20 in linear scale; we apply a mild power curve
    /// plus scaling so quiet speech still moves the waveform meaningfully.
    private func publishLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.int16ChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }

        let ptr = channelData[0]
        var sum: Double = 0
        for i in 0..<n {
            let s = Double(ptr[i]) / 32768.0
            sum += s * s
        }
        let rms = Float(sqrt(sum / Double(n)))
        // sqrt curve feels more responsive at low levels than raw RMS.
        let shaped = min(1.0, sqrt(rms) * 1.8)

        Task { @MainActor in
            AudioLevelMonitor.shared.update(shaped)
        }
    }
}
