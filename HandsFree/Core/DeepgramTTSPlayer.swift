import Foundation
import AVFoundation

/// Streams synthesized audio from Deepgram's `/v1/speak` endpoint straight
/// into an `AVAudioPlayerNode`, so playback begins on the first network
/// chunk instead of waiting for the whole response. Mono Int16 PCM at
/// 24 kHz — cheap to decode, no codec dependency.
final class DeepgramTTSPlayer: NSObject, ObservableObject {
    enum Voice: String, CaseIterable, Identifiable {
        case thalia    = "aura-2-thalia-en"
        case stella    = "aura-2-stella-en"
        case andromeda = "aura-2-andromeda-en"
        case luna      = "aura-2-luna-en"
        case apollo    = "aura-2-apollo-en"
        case arcas     = "aura-2-arcas-en"
        case orpheus   = "aura-2-orpheus-en"
        case zeus      = "aura-2-zeus-en"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .thalia:    return "Thalia — female, conversational"
            case .stella:    return "Stella — female, friendly"
            case .andromeda: return "Andromeda — female, calm"
            case .luna:      return "Luna — female, youthful"
            case .apollo:    return "Apollo — male, narrative"
            case .arcas:     return "Arcas — male, warm"
            case .orpheus:   return "Orpheus — male, deep"
            case .zeus:      return "Zeus — male, authoritative"
            }
        }

        static var defaultVoice: Voice { .thalia }
    }

    struct PlaybackError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published private(set) var isPlaying: Bool = false

    /// Called on the main queue once synthesis finished cleanly (all chunks
    /// scheduled and drained). Not called when `stop()` interrupted playback.
    var onFinished: (() -> Void)?
    /// Called on the main queue on network / HTTP errors.
    var onError: ((Error) -> Void)?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let delegateQueue: OperationQueue
    private var dataTask: URLSessionDataTask?
    private var pendingBuffers: Int = 0
    private var responseEnded: Bool = false
    private var startedPlayback: Bool = false
    /// Set by `stop()` so late delegate events (cancel races) can no-op.
    private var cancelled: Bool = false

    override init() {
        format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        )!
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "com.handsfree.tts.deepgram"
        delegateQueue = q
        super.init()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    }

    // MARK: - Public

    func speak(text: String, apiKey: String, voice: Voice) {
        stop()
        cancelled = false

        var comps = URLComponents(string: "https://api.deepgram.com/v1/speak")!
        comps.queryItems = [
            URLQueryItem(name: "model",       value: voice.rawValue),
            URLQueryItem(name: "encoding",    value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "24000"),
        ]
        guard let url = comps.url else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Token \(apiKey)",  forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])

        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            Log.error("tts", "engine start failed: \(error.localizedDescription)")
            dispatchError(error)
            return
        }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        dataTask = session.dataTask(with: req)
        setPlaying(true)
        dataTask?.resume()
    }

    func stop() {
        cancelled = true
        dataTask?.cancel()
        dataTask = nil
        if playerNode.isPlaying { playerNode.stop() }
        if engine.isRunning { engine.stop() }
        startedPlayback = false
        responseEnded = false
        pendingBuffers = 0
        setPlaying(false)
    }

    // MARK: - Internals

    private func setPlaying(_ value: Bool) {
        if Thread.isMainThread {
            isPlaying = value
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.isPlaying = value
            }
        }
    }

    private func dispatchError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(error)
        }
    }

    private func dispatchFinished() {
        DispatchQueue.main.async { [weak self] in
            self?.onFinished?()
        }
    }

    /// Copy raw Int16 LE PCM bytes from `data` into an `AVAudioPCMBuffer`
    /// that matches our engine format, and schedule it on the player node.
    private func schedule(_ data: Data) {
        guard !cancelled else { return }
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard frameCount > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        data.withUnsafeBytes { raw in
            guard let src = raw.baseAddress,
                  let dst = buffer.int16ChannelData else { return }
            memcpy(dst[0], src, Int(frameCount) * MemoryLayout<Int16>.size)
        }

        pendingBuffers += 1
        playerNode.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.delegateQueue.addOperation { [weak self] in
                guard let self, !self.cancelled else { return }
                self.pendingBuffers -= 1
                self.checkFinish()
            }
        }
        if !startedPlayback {
            playerNode.play()
            startedPlayback = true
        }
    }

    private func checkFinish() {
        guard responseEnded, pendingBuffers <= 0 else { return }
        if playerNode.isPlaying { playerNode.stop() }
        if engine.isRunning { engine.stop() }
        startedPlayback = false
        responseEnded = false
        setPlaying(false)
        dispatchFinished()
    }
}

// MARK: - URLSessionDataDelegate

extension DeepgramTTSPlayer: URLSessionDataDelegate {
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            Log.error("tts", "deepgram HTTP \(http.statusCode)")
            dispatchError(PlaybackError(message: "Deepgram returned HTTP \(http.statusCode)"))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        schedule(data)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error as NSError? {
            if error.code != NSURLErrorCancelled {
                Log.error("tts", "deepgram stream failed: \(error.localizedDescription)")
                dispatchError(error)
            }
            // Clean up silently on cancel or surface error on others.
            delegateQueue.addOperation { [weak self] in
                guard let self, !self.cancelled else { return }
                if self.playerNode.isPlaying { self.playerNode.stop() }
                if self.engine.isRunning { self.engine.stop() }
                self.startedPlayback = false
                self.responseEnded = false
                self.pendingBuffers = 0
                self.setPlaying(false)
            }
            return
        }
        responseEnded = true
        checkFinish()
    }
}
