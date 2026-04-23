import Foundation

/// File-backed storage for the Groq API key. Lives at
/// `~/Library/Application Support/HandsFree/groq-key` with mode 0600.
/// We use a file (not Keychain) because Keychain ACLs prompt for the user's
/// macOS password on every rebuild — the ACL binds to the code-directory hash
/// and we change that every Debug build. A user-only file works everywhere.
enum APIKeyStore {
    private static var fileURL: URL {
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
        return dir.appendingPathComponent("groq-key")
    }

    static func read() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func write(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = fileURL
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
            Log.error("secrets", "write failed: \(error.localizedDescription)")
        }
    }

    static func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    static var path: String { fileURL.path }
}
