import Foundation
import SQLite3

enum SQLBind { case int(Int64), double(Double), text(String), blob(Data), null }

struct SQLiteError: Error, CustomStringConvertible { var description: String }

/// Minimal SQLite wrapper over the system library. Not thread-safe by itself; `ClipStore` serialises access.
final class SQLiteDB {
    private var db: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw SQLiteError(description: "open \(path): \(message)")
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { sqlite3_close(db) }

    var message: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "no db" }
    var lastInsertID: Int64 { sqlite3_last_insert_rowid(db) }
    var changes: Int { Int(sqlite3_changes(db)) }

    func exec(_ sql: String, _ binds: [SQLBind] = []) throws {
        let st = try prepare(sql, binds)
        defer { sqlite3_finalize(st) }
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError(description: "\(message) in: \(sql)") }
    }

    func query<T>(_ sql: String, _ binds: [SQLBind] = [], _ row: (OpaquePointer) -> T) throws -> [T] {
        let st = try prepare(sql, binds)
        defer { sqlite3_finalize(st) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { out.append(row(st)) } else if rc == SQLITE_DONE { break }
            else { throw SQLiteError(description: "\(message) in: \(sql)") }
        }
        return out
    }

    private func prepare(_ sql: String, _ binds: [SQLBind]) throws -> OpaquePointer {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { throw SQLiteError(description: "\(message) in: \(sql)") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .int(let v): sqlite3_bind_int64(st, idx, v)
            case .double(let v): sqlite3_bind_double(st, idx, v)
            case .text(let v): sqlite3_bind_text(st, idx, v, -1, transient)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(st, idx, $0.baseAddress, Int32(v.count), transient) }
            case .null: sqlite3_bind_null(st, idx)
            }
        }
        return st
    }
}

extension OpaquePointer {
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(self, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(self, i) }
    func text(_ i: Int32) -> String? { sqlite3_column_text(self, i).map { String(cString: $0) } }
    func blob(_ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(self, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(self, i)))
    }
}
