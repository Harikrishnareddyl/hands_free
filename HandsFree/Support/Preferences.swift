import Foundation

/// Centralized UserDefaults-backed preferences.
enum Preferences {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let soundsEnabled = "soundsEnabled"         // legacy bool — migrated
        static let audioCueMode = "audioCueMode"
        static let transcriptionModel = "transcriptionModel"
        static let transcriptionVocabulary = "transcriptionVocabulary"
        static let language = "language"
        static let minDurationSeconds = "minDurationSeconds"
        static let askAIModel = "askAIModel"
        static let askAISystemPrompt = "askAISystemPrompt"
        static let wakeWordEnabled = "wakeWordEnabled"
        static let maxDurationSeconds = "maxDurationSeconds"
    }

    static let defaultAskAISystemPrompt = """
    You are a concise assistant answering a spoken question. \
    Reply in Markdown. Use fenced code blocks for code and short headings only when they help. \
    Keep prose tight — no filler, no repetition of the question.
    """

    // MARK: - Audio cues (Off / chimes only / all)
    static var audioCueMode: AudioCueMode {
        get {
            if let raw = defaults.string(forKey: Key.audioCueMode),
               let mode = AudioCueMode(rawValue: raw) {
                return mode
            }
            // Migrate from the old bool. True → all cues, false → off.
            if let legacy = defaults.object(forKey: Key.soundsEnabled) as? Bool {
                return legacy ? .all : .off
            }
            return .all
        }
        set { defaults.set(newValue.rawValue, forKey: Key.audioCueMode) }
    }

    // MARK: - Transcription model
    static var transcriptionModel: String {
        get { defaults.string(forKey: Key.transcriptionModel) ?? GroqClient.Model.whisperTurbo }
        set { defaults.set(newValue, forKey: Key.transcriptionModel) }
    }

    // MARK: - Optional language hint (ISO-639-1). Empty = auto-detect.
    static var language: String {
        get { defaults.string(forKey: Key.language) ?? "" }
        set { defaults.set(newValue, forKey: Key.language) }
    }

    // MARK: - Vocabulary hints fed to Whisper as its `prompt` parameter.
    // Max ~224 tokens per Groq docs.
    static var transcriptionVocabulary: String {
        get { defaults.string(forKey: Key.transcriptionVocabulary) ?? "" }
        set { defaults.set(newValue, forKey: Key.transcriptionVocabulary) }
    }

    // MARK: - Minimum clip duration to bother transcribing (seconds).
    static var minDurationSeconds: Double {
        get {
            let v = defaults.double(forKey: Key.minDurationSeconds)
            return v <= 0 ? 1.0 : v
        }
        set { defaults.set(newValue, forKey: Key.minDurationSeconds) }
    }

    // MARK: - Maximum recording duration (seconds). Applies to every mode —
    // hold-to-talk, Fn hands-free, Ask AI, wake-word. A safety net against a
    // stuck key or runaway session eating Groq credits.
    static var maxDurationSeconds: Double {
        get {
            let v = defaults.double(forKey: Key.maxDurationSeconds)
            return v <= 0 ? 180.0 : v
        }
        set { defaults.set(max(5, newValue), forKey: Key.maxDurationSeconds) }
    }

    // MARK: - Ask AI (separate from transcription)
    static var askAIModel: String {
        get { defaults.string(forKey: Key.askAIModel) ?? GroqClient.LLMModel.llama33_70b }
        set { defaults.set(newValue, forKey: Key.askAIModel) }
    }

    static var askAISystemPrompt: String {
        get { defaults.string(forKey: Key.askAISystemPrompt) ?? defaultAskAISystemPrompt }
        set { defaults.set(newValue, forKey: Key.askAISystemPrompt) }
    }

    // MARK: - Wake word (opt-in; off by default).
    static var wakeWordEnabled: Bool {
        get { defaults.bool(forKey: Key.wakeWordEnabled) }
        set {
            defaults.set(newValue, forKey: Key.wakeWordEnabled)
            NotificationCenter.default.post(name: .wakeWordPreferenceChanged, object: nil)
        }
    }
}

extension Notification.Name {
    /// Posted whenever `Preferences.wakeWordEnabled` changes. AppDelegate
    /// observes this to start/stop the always-on listener.
    static let wakeWordPreferenceChanged = Notification.Name("handsfree.wakeWordPreferenceChanged")
}
