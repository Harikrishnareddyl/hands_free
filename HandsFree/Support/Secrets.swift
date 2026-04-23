import Foundation

enum Secrets {
    /// Resolves the Groq API key in this order:
    ///   1. `GROQ_API_KEY` env var (never persisted)
    ///   2. `~/Library/Application Support/HandsFree/groq-key` (primary)
    ///   3. `~/.config/handsfree/groq-key` (legacy — auto-migrated to primary on read)
    static func groqAPIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["GROQ_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }

        if let file = APIKeyStore.read() {
            return file
        }

        // Migrate legacy ~/.config location into the primary file.
        let legacyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/handsfree/groq-key")
        if let contents = try? String(contentsOf: legacyPath, encoding: .utf8) {
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                Log.info("secrets", "migrating key from ~/.config → Application Support")
                APIKeyStore.write(trimmed)
                return trimmed
            }
        }

        return nil
    }

    /// Deepgram key for the optional cloud TTS path. Same resolution order:
    ///   1. `DEEPGRAM_API_KEY` env var (never persisted)
    ///   2. `~/Library/Application Support/HandsFree/deepgram-key` (0600)
    /// Missing key → returns nil and the app falls back to the built-in voice.
    static func deepgramAPIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        return APIKeyStore.read(name: "deepgram-key")
    }
}
