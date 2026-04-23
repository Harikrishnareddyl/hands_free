import Foundation
import AVFoundation

/// Answer-card text-to-speech. Picks between a cloud streamable provider
/// (Deepgram) and the built-in `AVSpeechSynthesizer` at `speak()` time:
/// if the user has enabled cloud TTS in Settings and a key is configured,
/// Deepgram plays; otherwise the on-device voice plays. Exposes a single
/// `isSpeaking` flag that the UI binds to regardless of which engine ran.
@MainActor
final class SpeechManager: ObservableObject {
    @Published private(set) var isSpeaking: Bool = false

    private let synthesizer = AVSpeechSynthesizer()
    private var synthDelegate: Delegate?
    private let deepgram = DeepgramTTSPlayer()

    init() {
        let d = Delegate()
        d.owner = self
        synthDelegate = d
        synthesizer.delegate = d

        deepgram.onFinished = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleCloudEnded()
            }
        }
        deepgram.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                Log.error("speech", "cloud TTS error: \(error.localizedDescription)")
                self?.handleCloudEnded()
            }
        }
    }

    /// Speak the given text. Cancels any in-flight utterance first.
    func speak(_ text: String) {
        stop()
        let cleaned = Self.plainText(from: text)
        guard !cleaned.isEmpty else { return }

        if Preferences.cloudTTSEnabled,
           let key = Secrets.deepgramAPIKey() {
            let voice = DeepgramTTSPlayer.Voice(rawValue: Preferences.deepgramVoice)
                ?? .defaultVoice
            isSpeaking = true
            deepgram.speak(text: cleaned, apiKey: key, voice: voice)
        } else {
            let utterance = AVSpeechUtterance(string: cleaned)
            let langCode = AVSpeechSynthesisVoice.currentLanguageCode()
            utterance.voice = AVSpeechSynthesisVoice(language: langCode)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = 1.0
            utterance.volume = 1.0
            isSpeaking = true
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        deepgram.stop()
        isSpeaking = false
    }

    fileprivate func handleSynthEnded() {
        isSpeaking = false
    }

    private func handleCloudEnded() {
        isSpeaking = false
    }

    /// Strip markdown markers so the synthesizer reads the prose rather than
    /// the syntax. Not a full parser — just the common cases that appear in
    /// LLM replies: code fences, inline code, bold/italic markers, heading
    /// hashes, and link `[text](url)` syntax.
    private static func plainText(from markdown: String) -> String {
        var s = markdown
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\*([^*]+)\\*", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "__([^_]+)__", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "_([^_]+)_", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "^\\s*#+\\s*", with: "", options: [.regularExpression, .anchored])
        s = s.replacingOccurrences(of: "\n\\s*#+\\s*", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "^\\s*[-*+]\\s+", with: "", options: [.regularExpression, .anchored])
        s = s.replacingOccurrences(of: "\n\\s*[-*+]\\s+", with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private final class Delegate: NSObject, AVSpeechSynthesizerDelegate {
        weak var owner: SpeechManager?

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                               didFinish utterance: AVSpeechUtterance) {
            Task { @MainActor in self.owner?.handleSynthEnded() }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                               didCancel utterance: AVSpeechUtterance) {
            Task { @MainActor in self.owner?.handleSynthEnded() }
        }
    }
}
