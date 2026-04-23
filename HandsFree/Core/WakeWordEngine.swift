@preconcurrency import AVFoundation
import Foundation
import LiveKitWakeWord

/// Always-on wake-word listener. Runs its own `AVAudioEngine` tap in parallel
/// with `AudioRecorder` — when the wake word fires, we hand off to the normal
/// dictation pipeline via `onDetected`.
///
/// `suspend()` / `resume()` let `AppDelegate` release the mic while the user
/// is actively recording a clip (hotkey down, Fn hands-free, Ask-AI). Two
/// engines on one input device is fragile on macOS; yielding the mic is
/// cheaper than debugging a race.
final class WakeWordEngine: @unchecked Sendable {
    /// Filename (without extension) of the classifier .onnx bundled in
    /// `Resources/`. Swap this (and update `wakePhrase`) to ship a different
    /// wake word — no other code changes required.
    // static let bundledClassifierName = "hey_livekit"
    static let bundledClassifierName = "hey_aira"
    /// User-facing label for the bundled wake word.
    // static let wakePhrase = "Hey LiveKit"
    static let wakePhrase = "Hey Aira"

    /// Called on the main actor when the wake word fires above threshold.
    var onDetected: (() -> Void)?

    // MARK: - Tuning

    /// Confidence above which we treat it as a real detection. Read from
    /// `Preferences.wakeWordThreshold` on every prediction so the Settings
    /// slider takes effect immediately without restarting the engine.
    private var triggerThreshold: Float {
        Float(Preferences.wakeWordThreshold)
    }
    /// After a detection, suppress further triggers for this long. Avoids
    /// re-firing from the tail of the same utterance.
    private let debounceSeconds: TimeInterval = 2.0
    /// Gap between predictions. LiveKit's reference uses 20 ms (50 Hz) which
    /// is overkill — the wake phrase is ~1 s long and the ring already holds
    /// a 2-second window, so 80 ms (~12 Hz) catches every utterance with no
    /// user-perceptible latency while cutting idle CPU ~4×.
    private let predictInterval: CFAbsoluteTime = 0.08
    private let windowSeconds: Double = 2.0

    // MARK: - State

    private var model: WakeWordModel?
    /// The execution provider the cached `model` was built with. We rebuild
    /// the model if the user changes this via Settings.
    private var modelProvider: Preferences.WakeWordExecutionProvider?
    private var engine: AVAudioEngine?
    private let workQueue = DispatchQueue(
        label: "com.lakkireddylabs.HandsFree.wakeword",
        qos: .userInteractive
    )

    private let ringLock = NSLock()
    private var ring: [Int16] = []
    private var writeIdx = 0
    private var samplesWritten = 0
    private var lastPredictAt: CFAbsoluteTime = 0
    private var predictInFlight = false
    private var cooldownUntil: CFAbsoluteTime = 0

    private(set) var isRunning = false

    /// The execution provider currently in effect (matches the cached model,
    /// or — if the model hasn't been built yet — the one we'll build next).
    /// Used by `AppDelegate` to decide whether to cycle the engine after a
    /// preference change.
    var activeProvider: Preferences.WakeWordExecutionProvider {
        modelProvider ?? Preferences.wakeWordExecutionProvider
    }

    // MARK: - Lifecycle

    /// Start listening. Silently no-ops if already running. Throws if the
    /// model file is missing or the engine can't start.
    @MainActor
    func start() throws {
        guard !isRunning else { return }

        let desiredProvider = Preferences.wakeWordExecutionProvider
        if model == nil || modelProvider != desiredProvider {
            guard let url = Bundle.main.url(
                forResource: Self.bundledClassifierName,
                withExtension: "onnx"
            ) else {
                throw NSError(
                    domain: "WakeWordEngine",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "\(Self.bundledClassifierName).onnx not found in bundle"]
                )
            }
            model = try WakeWordModel(
                models: [url],
                sampleRate: WakeWordModel.modelSampleRate,
                executionProvider: desiredProvider.ortProvider
            )
            modelProvider = desiredProvider
            Log.info("wake", "model built with provider=\(desiredProvider.rawValue)")
        }

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0 else {
            throw NSError(
                domain: "WakeWordEngine",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No valid mic input format"]
            )
        }

        let modelRate = Double(WakeWordModel.modelSampleRate)
        let ringSize = max(Int(modelRate * windowSeconds), 1)
        ringLock.lock()
        if ring.count != ringSize {
            ring = [Int16](repeating: 0, count: ringSize)
        }
        writeIdx = 0
        samplesWritten = 0
        lastPredictAt = 0
        predictInFlight = false
        cooldownUntil = 0
        ringLock.unlock()

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: modelRate,
            channels: 1,
            interleaved: true
        ),
        let converter = AVAudioConverter(from: hwFormat, to: targetFormat)
        else {
            throw NSError(
                domain: "WakeWordEngine",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not build audio converter"]
            )
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.handleInput(buffer: buffer, converter: converter, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        Log.info("wake", "listening for '\(Self.wakePhrase)'")
    }

    @MainActor
    func stop() {
        guard isRunning else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        ringLock.lock()
        writeIdx = 0
        samplesWritten = 0
        predictInFlight = false
        ringLock.unlock()
        isRunning = false
        Log.info("wake", "stopped")
    }

    // MARK: - Audio tap (real-time thread)

    private func handleInput(
        buffer inputBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: inputBuffer.frameCapacity
        ) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, error == nil,
              let channelData = outBuffer.int16ChannelData else { return }

        let frameCount = Int(outBuffer.frameLength)
        guard frameCount > 0 else { return }

        let shouldRun = appendAndCheck(samples: channelData[0], count: frameCount)
        if shouldRun, let snapshot = snapshotRing() {
            workQueue.async { [weak self] in
                self?.runPredict(snapshot: snapshot)
            }
        }
    }

    private func appendAndCheck(samples: UnsafePointer<Int16>, count: Int) -> Bool {
        ringLock.lock()
        defer { ringLock.unlock() }

        let size = ring.count
        guard size > 0 else { return false }
        var idx = writeIdx
        for i in 0..<count {
            ring[idx] = samples[i]
            idx += 1
            if idx >= size { idx = 0 }
        }
        writeIdx = idx
        samplesWritten = min(samplesWritten + count, size)

        guard samplesWritten >= size else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        guard now >= cooldownUntil else { return false }
        guard (now - lastPredictAt) >= predictInterval else { return false }
        guard !predictInFlight else { return false }
        lastPredictAt = now
        predictInFlight = true
        return true
    }

    private func snapshotRing() -> [Int16]? {
        ringLock.lock()
        defer { ringLock.unlock() }
        let size = ring.count
        guard samplesWritten >= size, size > 0 else { return nil }
        var out = [Int16](repeating: 0, count: size)
        let tail = size - writeIdx
        out.withUnsafeMutableBufferPointer { dst in
            ring.withUnsafeBufferPointer { src in
                guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return }
                dstBase.update(from: srcBase + writeIdx, count: tail)
                if writeIdx > 0 {
                    (dstBase + tail).update(from: srcBase, count: writeIdx)
                }
            }
        }
        return out
    }

    private func runPredict(snapshot: [Int16]) {
        defer {
            ringLock.lock()
            predictInFlight = false
            ringLock.unlock()
        }
        guard let model else { return }
        do {
            let scores = try model.predict(snapshot)
            guard let maxScore = scores.values.max(), maxScore >= triggerThreshold else { return }
            Log.info("wake", "detected score=\(String(format: "%.2f", maxScore))")

            // Arm cooldown + clear the ring so the recognized audio isn't
            // re-evaluated the next tick.
            ringLock.lock()
            cooldownUntil = CFAbsoluteTimeGetCurrent() + debounceSeconds
            writeIdx = 0
            samplesWritten = 0
            ringLock.unlock()

            Task { @MainActor [weak self] in
                self?.onDetected?()
            }
        } catch {
            Log.error("wake", "predict failed: \(error.localizedDescription)")
        }
    }
}

private extension Preferences.WakeWordExecutionProvider {
    var ortProvider: ExecutionProvider {
        switch self {
        case .coreML:          return .coreML
        case .coreMLCPUAndGPU: return .coreMLCPUAndGPU
        case .coreMLCPUOnly:   return .coreMLCPUOnly
        case .cpu:             return .cpu
        }
    }
}
