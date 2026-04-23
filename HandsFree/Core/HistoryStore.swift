import Foundation
import GRDB

extension Notification.Name {
    static let historyDidChange = Notification.Name("com.lakkireddylabs.HandsFree.historyDidChange")
}

/// SQLite-backed history of all transcriptions. File lives at
/// `~/Library/Application Support/HandsFree/history.sqlite`.
final class HistoryStore {
    static let shared: HistoryStore = {
        do {
            return try HistoryStore()
        } catch {
            Log.error("history", "could not open DB: \(error.localizedDescription)")
            // Fall back to an in-memory DB so the app keeps working even if
            // disk writes fail. Data won't persist but the pipeline won't crash.
            return (try? HistoryStore(inMemory: true)) ?? HistoryStore.unavailable()
        }
    }()

    struct Entry: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {
        static let databaseTableName = "transcription"

        var id: Int64?
        var createdAt: Date
        var raw: String
        var cleaned: String
        var appBundleID: String?
        var durationSeconds: Double
        var model: String

        enum Columns {
            static let id = Column(CodingKeys.id)
            static let createdAt = Column(CodingKeys.createdAt)
            static let raw = Column(CodingKeys.raw)
            static let cleaned = Column(CodingKeys.cleaned)
            static let appBundleID = Column(CodingKeys.appBundleID)
            static let durationSeconds = Column(CodingKeys.durationSeconds)
            static let model = Column(CodingKeys.model)
        }

        mutating func didInsert(_ inserted: InsertionSuccess) {
            id = inserted.rowID
        }
    }

    private let queue: DatabaseQueue
    private let available: Bool

    private init(inMemory: Bool = false) throws {
        if inMemory {
            queue = try DatabaseQueue()
        } else {
            let dir = try Self.applicationSupportDirectory()
            let url = dir.appendingPathComponent("history.sqlite")
            Log.info("history", "opening DB at \(url.path)")
            queue = try DatabaseQueue(path: url.path)
        }
        available = true
        try Self.migrator.migrate(queue)
    }

    private init(unavailableSentinel: Void) {
        queue = try! DatabaseQueue()
        available = false
    }

    private static func unavailable() -> HistoryStore {
        HistoryStore(unavailableSentinel: ())
    }

    private static func applicationSupportDirectory() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("HandsFree", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: Entry.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("raw", .text).notNull()
                t.column("cleaned", .text).notNull()
                t.column("appBundleID", .text)
                t.column("durationSeconds", .double).notNull()
                t.column("model", .text).notNull()
            }
        }
        return m
    }

    // MARK: - API

    @discardableResult
    func insert(_ entry: Entry) -> Int64? {
        guard available else { return nil }
        do {
            let id = try queue.write { db -> Int64 in
                var mutable = entry
                try mutable.insert(db)
                return mutable.id ?? 0
            }
            NotificationCenter.default.post(name: .historyDidChange, object: nil)
            return id
        } catch {
            Log.error("history", "insert failed: \(error.localizedDescription)")
            return nil
        }
    }

    func fetchAll(search: String = "", limit: Int = 500) -> [Entry] {
        fetchPage(search: search, offset: 0, limit: limit)
    }

    /// Paginated fetch for lazy-loading the history window.
    func fetchPage(search: String, offset: Int, limit: Int) -> [Entry] {
        guard available else { return [] }
        do {
            return try queue.read { db in
                var request = Entry
                    .order(Entry.Columns.createdAt.desc)
                    .limit(limit, offset: offset)

                let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
                if !q.isEmpty {
                    let like = "%\(q)%"
                    request = request.filter(
                        Entry.Columns.raw.like(like)
                        || Entry.Columns.cleaned.like(like)
                        || Entry.Columns.appBundleID.like(like)
                    )
                }
                return try Entry.fetchAll(db, request)
            }
        } catch {
            Log.error("history", "fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    func delete(id: Int64) {
        guard available else { return }
        do {
            try queue.write { db in
                _ = try Entry.deleteOne(db, key: id)
            }
            NotificationCenter.default.post(name: .historyDidChange, object: nil)
        } catch {
            Log.error("history", "delete failed: \(error.localizedDescription)")
        }
    }

    func deleteAll() {
        guard available else { return }
        do {
            try queue.write { db in
                _ = try Entry.deleteAll(db)
            }
            NotificationCenter.default.post(name: .historyDidChange, object: nil)
        } catch {
            Log.error("history", "deleteAll failed: \(error.localizedDescription)")
        }
    }

    func count() -> Int {
        guard available else { return 0 }
        return (try? queue.read { db in try Entry.fetchCount(db) }) ?? 0
    }
}
