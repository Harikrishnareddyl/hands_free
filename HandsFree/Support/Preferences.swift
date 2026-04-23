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
    }

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
            return v <= 0 ? 2.0 : v
        }
        set { defaults.set(newValue, forKey: Key.minDurationSeconds) }
    }
}
