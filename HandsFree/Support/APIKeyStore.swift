import Foundation

/// File-backed storage for provider API keys. Each key lives at
/// `~/Library/Application Support/HandsFree/<name>` with mode 0600.
/// We use files (not Keychain) because Keychain ACLs prompt for the user's
/// macOS password on every rebuild — the ACL binds to the code-directory hash
/// and we change that every Debug build. A user-only file works everywhere.
enum APIKeyStore {
    // MARK: - Backwards-compatible Groq accessors
    static func read() -> String? { read(name: "groq-key") }
    static func write(_ value: String) { write(value, name: "groq-key") }
    static func remove() { remove(name: "groq-key") }
    static var path: String { fileURL(name: "groq-key").path }

    // MARK: - Generalized accessors (any named key file)
    static func read(name: String) -> String? {
        let url = fileURL(name: name)
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func write(_ value: String, name: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = fileURL(name: name)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try trimmed.data(using: .utf8)?.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            Log.error("secrets", "write failed for \(name): \(error.localizedDescription)")
        }
    }

    static func remove(name: String) {
        try? FileManager.default.removeItem(at: fileURL(name: name))
    }

    static func path(for name: String) -> String { fileURL(name: name).path }

    // MARK: - Internals
    private static func fileURL(name: String) -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("HandsFree", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(name)
    }
}
