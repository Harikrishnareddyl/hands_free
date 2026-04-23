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
        static let wakeWordExecutionProvider = "wakeWordExecutionProvider"
        static let wakeWordThreshold = "wakeWordThreshold"
        static let wakeWordAction = "wakeWordAction"
        static let maxDurationSeconds = "maxDurationSeconds"
        static let answerAutoHideEnabled = "answerAutoHideEnabled"
        static let answerAutoHideSeconds = "answerAutoHideSeconds"
        static let speakAnswersEnabled = "speakAnswersEnabled"
        static let speakAnswersMuted = "speakAnswersMuted"
        static let cloudTTSEnabled = "cloudTTSEnabled"
        static let cloudTTSProvider = "cloudTTSProvider"
        static let deepgramVoice = "deepgramVoice"
    }

    enum CloudTTSProvider: String, CaseIterable, Identifiable {
        case deepgram

        var id: String { rawValue }
        var label: String {
            switch self {
            case .deepgram: return "Deepgram"
            }
        }
        var keyName: String {
            switch self {
            case .deepgram: return "deepgram-key"
            }
        }
    }

    /// What the \u{201C}Hey Aira\u{201D} wake word triggers. Default is
    /// dictation to preserve pre-upgrade behavior; users can switch to Ask AI
    /// from Settings when they want the floating-answer card instead.
    enum WakeWordAction: String, CaseIterable, Identifiable {
        case dictate
        case askAI

        var id: String { rawValue }
        var label: String {
            switch self {
            case .dictate: return "Dictate"
            case .askAI:   return "Ask AI"
            }
        }
    }

    /// ONNX Runtime execution provider used by the wake-word model. Mirrors
    /// the four options LiveKit ships in their reference demo — the right
    /// choice is device- and model-dependent, so we expose it so users can
    /// A/B the CPU and energy impact in Activity Monitor.
    enum WakeWordExecutionProvider: String, CaseIterable, Identifiable {
        case coreML
        case coreMLCPUAndGPU
        case coreMLCPUOnly
        case cpu

        var id: String { rawValue }

        var label: String {
            switch self {
            case .coreML:          return "CoreML (ANE + GPU + CPU)"
            case .coreMLCPUAndGPU: return "CoreML (GPU + CPU)"
            case .coreMLCPUOnly:   return "CoreML (CPU only)"
            case .cpu:             return "ORT CPU"
            }
        }
    }

    static let defaultAskAISystemPrompt = """
    You are a concise assistant answering a spoken question. The user's message was \
    transcribed from speech, so expect occasional homophones, missing punctuation, or \
    odd capitalization — infer intent charitably instead of asking for clarification. \
    Your reply will be read aloud by a text-to-speech engine, so write plain prose that \
    sounds natural spoken. Start with the answer directly — no title line, no headings, \
    no preamble like \u{201C}Sure\u{201D} or \u{201C}Here is\u{201D}. Avoid bullet lists, \
    tables, code blocks, and emoji unless the user explicitly asks for code. Keep it \
    tight: two or three short sentences for simple questions; a little longer only when \
    real detail is needed.
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

    // MARK: - Spoken answers (text-to-speech)
    /// Master switch. When off, the answer card hides its speaker button and
    /// never reads replies aloud. Default on.
    static var speakAnswersEnabled: Bool {
        get {
            if defaults.object(forKey: Key.speakAnswersEnabled) == nil { return true }
            return defaults.bool(forKey: Key.speakAnswersEnabled)
        }
        set { defaults.set(newValue, forKey: Key.speakAnswersEnabled) }
    }

    /// Per-panel mute toggled by the speaker button. Persists so a mute
    /// chosen during one answer applies to the next one too. Default off
    /// (answers auto-play).
    static var speakAnswersMuted: Bool {
        get { defaults.bool(forKey: Key.speakAnswersMuted) }
        set { defaults.set(newValue, forKey: Key.speakAnswersMuted) }
    }

    /// Opt-in cloud TTS. Default off — answers use the built-in macOS
    /// voice until the user explicitly enables this and supplies a key.
    /// The SpeechManager also re-reads `Secrets.deepgramAPIKey()` at
    /// speak-time and falls back silently to the system voice if the
    /// key file is missing.
    static var cloudTTSEnabled: Bool {
        get { defaults.bool(forKey: Key.cloudTTSEnabled) }
        set { defaults.set(newValue, forKey: Key.cloudTTSEnabled) }
    }

    static var cloudTTSProvider: CloudTTSProvider {
        get {
            guard let raw = defaults.string(forKey: Key.cloudTTSProvider),
                  let value = CloudTTSProvider(rawValue: raw) else {
                return .deepgram
            }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Key.cloudTTSProvider) }
    }

    /// Deepgram Aura-2 voice model id (e.g. `aura-2-thalia-en`). The
    /// `DeepgramTTSPlayer.Voice` enum is the source of truth for the
    /// available options; this string stays decoupled so new voices can
    /// be added without a Preferences migration.
    static var deepgramVoice: String {
        get { defaults.string(forKey: Key.deepgramVoice) ?? "aura-2-thalia-en" }
        set { defaults.set(newValue, forKey: Key.deepgramVoice) }
    }

    // MARK: - Answer card auto-hide
    /// When on, the floating answer panel dismisses itself after
    /// `answerAutoHideSeconds` of no interaction (and no active speech).
    /// Default on — the card is meant to be glanceable, not persistent.
    static var answerAutoHideEnabled: Bool {
        get {
            if defaults.object(forKey: Key.answerAutoHideEnabled) == nil { return true }
            return defaults.bool(forKey: Key.answerAutoHideEnabled)
        }
        set { defaults.set(newValue, forKey: Key.answerAutoHideEnabled) }
    }

    static var answerAutoHideSeconds: Double {
        get {
            let v = defaults.double(forKey: Key.answerAutoHideSeconds)
            return v <= 0 ? 30.0 : v
        }
        set { defaults.set(max(5, newValue), forKey: Key.answerAutoHideSeconds) }
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

    /// Which flow the wake word starts. Users can switch in Settings.
    static var wakeWordAction: WakeWordAction {
        get {
            guard let raw = defaults.string(forKey: Key.wakeWordAction),
                  let value = WakeWordAction(rawValue: raw) else {
                return .dictate
            }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Key.wakeWordAction) }
    }

    static var wakeWordExecutionProvider: WakeWordExecutionProvider {
        get {
            guard let raw = defaults.string(forKey: Key.wakeWordExecutionProvider),
                  let value = WakeWordExecutionProvider(rawValue: raw) else {
                return .coreML
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.wakeWordExecutionProvider)
            NotificationCenter.default.post(name: .wakeWordPreferenceChanged, object: nil)
        }
    }

    /// Confidence above which a wake-word prediction counts as a detection.
    /// Read on every prediction (hot path but cheap). Default 0.5 matches
    /// the v0.3.0 hey_aira model's real-voice output distribution. Lower
    /// in noisy rooms where the speaker sounds indistinct; raise if false
    /// triggers become annoying.
    static var wakeWordThreshold: Double {
        get {
            let v = defaults.double(forKey: Key.wakeWordThreshold)
            // 0.0 is the "not set" sentinel since we never want a real 0.
            return v <= 0 ? 0.5 : v
        }
        set {
            // Clamp to a reasonable UI range so a typo can't silently
            // disable the feature (0.0) or make it impossible to trigger (1.0).
            let clamped = max(0.10, min(0.95, newValue))
            defaults.set(clamped, forKey: Key.wakeWordThreshold)
        }
    }
}

extension Notification.Name {
    /// Posted whenever `Preferences.wakeWordEnabled` changes. AppDelegate
    /// observes this to start/stop the always-on listener.
    static let wakeWordPreferenceChanged = Notification.Name("handsfree.wakeWordPreferenceChanged")
}
