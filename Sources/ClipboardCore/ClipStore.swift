import Foundation
import CryptoKit

/// SQLite-backed history. Images live as PNG files beside the database. All access is serialised.
public final class ClipStore: @unchecked Sendable {
    private let db: SQLiteDB
    private let queue = DispatchQueue(label: "gg.tico.whopper.clipstore")
    public let imagesDir: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        imagesDir = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        db = try SQLiteDB(path: directory.appendingPathComponent("clipboard.sqlite").path)
        try db.exec("PRAGMA journal_mode=WAL")
        try db.exec("""
            CREATE TABLE IF NOT EXISTS items(
              id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, title TEXT, text TEXT, search TEXT NOT NULL DEFAULT '',
              preview TEXT NOT NULL DEFAULT '', rtf BLOB, html BLOB, image_file TEXT, files TEXT,
              source_app TEXT, source_bundle TEXT, created REAL NOT NULL, used REAL NOT NULL,
              use_count INTEGER NOT NULL DEFAULT 1, pinned INTEGER NOT NULL DEFAULT 0, snippet INTEGER NOT NULL DEFAULT 0,
              size INTEGER NOT NULL DEFAULT 0, hash TEXT NOT NULL UNIQUE)
            """)
        try db.exec("CREATE INDEX IF NOT EXISTS items_used ON items(pinned DESC, used DESC)")
    }

    public static func defaultDirectory() -> URL {
        if let d = ProcessInfo.processInfo.environment["WHOPPER_DATA_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true).appendingPathComponent("Clipboard", isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whopper/Clipboard", isDirectory: true)
    }

    private static let cols = "id,kind,title,preview,image_file,files,source_app,source_bundle,created,used,use_count,pinned,snippet,size,(rtf IS NOT NULL OR html IS NOT NULL)"

    private static func item(_ r: OpaquePointer) -> ClipItem {
        let files = (r.text(5)).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        return ClipItem(id: r.int(0), kind: ClipKind(rawValue: r.text(1) ?? "text") ?? .text, title: r.text(2), preview: r.text(3) ?? "",
                        imageFile: r.text(4), files: files, sourceApp: r.text(6), sourceBundle: r.text(7),
                        createdAt: Date(timeIntervalSince1970: r.double(8)), lastUsedAt: Date(timeIntervalSince1970: r.double(9)),
                        useCount: Int(r.int(10)), pinned: r.int(11) != 0, isSnippet: r.int(12) != 0, byteSize: Int(r.int(13)), hasRich: r.int(14) != 0)
    }

    private static func hash(_ c: ClipCapture) -> String {
        var h = SHA256()
        h.update(data: Data(c.kind.rawValue.utf8))
        if let t = c.text { h.update(data: Data(t.utf8)) }
        if let i = c.imageData { h.update(data: i) }
        for f in c.files { h.update(data: Data(f.utf8)) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Writing

    /// Stores a capture. An identical earlier entry is moved to the top instead of duplicated. Returns its id.
    @discardableResult
    public func add(_ c: ClipCapture, now: Date = Date()) -> Int64? {
        queue.sync {
            let hash = Self.hash(c)
            do {
                if let existing = try db.query("SELECT id FROM items WHERE hash=?", [.text(hash)], { $0.int(0) }).first {
                    try db.exec("UPDATE items SET used=?, use_count=use_count+1, source_app=COALESCE(?,source_app), source_bundle=COALESCE(?,source_bundle) WHERE id=?",
                                [.double(now.timeIntervalSince1970), c.sourceApp.map(SQLBind.text) ?? .null, c.sourceBundle.map(SQLBind.text) ?? .null, .int(existing)])
                    return existing
                }
                var imageFile: String?
                if let img = c.imageData {
                    imageFile = hash + ".png"
                    try img.write(to: imagesDir.appendingPathComponent(imageFile!), options: .atomic)
                }
                let preview = CaptureRules.preview(of: c)
                let size = (c.text?.utf8.count ?? 0) + (c.imageData?.count ?? 0) + (c.rtf?.count ?? 0) + (c.html?.count ?? 0)
                let filesJSON = c.files.isEmpty ? nil : String(data: try JSONEncoder().encode(c.files), encoding: .utf8)
                try db.exec("""
                    INSERT INTO items(kind,text,search,preview,rtf,html,image_file,files,source_app,source_bundle,created,used,size,hash)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [.text(c.kind.rawValue), c.text.map(SQLBind.text) ?? .null,
                          .text(CaptureRules.fold(preview + " " + (c.text ?? "") + " " + (c.sourceApp ?? ""))),
                          .text(preview), c.rtf.map(SQLBind.blob) ?? .null, c.html.map(SQLBind.blob) ?? .null,
                          imageFile.map(SQLBind.text) ?? .null, filesJSON.map(SQLBind.text) ?? .null,
                          c.sourceApp.map(SQLBind.text) ?? .null, c.sourceBundle.map(SQLBind.text) ?? .null,
                          .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970), .int(Int64(size)), .text(hash)])
                return db.lastInsertID
            } catch { return nil }
        }
    }

    /// A user-written snippet (always pinned).
    @discardableResult
    public func addSnippet(title: String, text: String, now: Date = Date()) -> Int64? {
        guard let id = add(ClipCapture(kind: .text, text: text), now: now) else { return nil }
        queue.sync {
            try? db.exec("UPDATE items SET snippet=1, pinned=1, title=?, search=? WHERE id=?",
                         [.text(title), .text(CaptureRules.fold(title + " " + text)), .int(id)])
        }
        return id
    }

    public func setPinned(_ id: Int64, _ pinned: Bool) { queue.sync { try? db.exec("UPDATE items SET pinned=? WHERE id=?", [.int(pinned ? 1 : 0), .int(id)]) } }
    public func markUsed(_ id: Int64, now: Date = Date()) {
        queue.sync { try? db.exec("UPDATE items SET used=?, use_count=use_count+1 WHERE id=?", [.double(now.timeIntervalSince1970), .int(id)]) }
    }

    public func delete(_ id: Int64) {
        queue.sync {
            if let f = try? db.query("SELECT image_file FROM items WHERE id=?", [.int(id)], { $0.text(0) }).first ?? nil {
                try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(f))
            }
            try? db.exec("DELETE FROM items WHERE id=?", [.int(id)])
        }
    }

    public func clearUnpinned() {
        queue.sync {
            let files = (try? db.query("SELECT image_file FROM items WHERE pinned=0 AND image_file IS NOT NULL", [], { $0.text(0) })) ?? []
            for f in files.compactMap({ $0 }) { try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(f)) }
            try? db.exec("DELETE FROM items WHERE pinned=0")
        }
    }

    /// Drops unpinned entries beyond the count or age limits.
    public func prune(maxItems: Int, maxAgeDays: Int, now: Date = Date()) {
        queue.sync {
            let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86_400).timeIntervalSince1970
            let doomed = (try? db.query("""
                SELECT id, image_file FROM items WHERE pinned=0 AND (used < ? OR id NOT IN
                  (SELECT id FROM items WHERE pinned=0 ORDER BY used DESC LIMIT ?))
                """, [.double(cutoff), .int(Int64(maxItems))], { ($0.int(0), $0.text(1)) })) ?? []
            for (id, f) in doomed {
                if let f { try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(f)) }
                try? db.exec("DELETE FROM items WHERE id=?", [.int(id)])
            }
        }
    }

    // MARK: Reading

    public func list(filter: ClipListFilter = .all, query: String = "", limit: Int = 200) -> [ClipItem] {
        queue.sync {
            var clauses: [String] = [], binds: [SQLBind] = []
            switch filter {
            case .all: break
            case .text: clauses.append("kind='text'")
            case .images: clauses.append("kind='image'")
            case .files: clauses.append("kind='files'")
            case .pinned: clauses.append("pinned=1")
            }
            for term in CaptureRules.fold(query).split(whereSeparator: \.isWhitespace) {
                let esc = term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                clauses.append("search LIKE ? ESCAPE '\\'"); binds.append(.text("%\(esc)%"))
            }
            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            binds.append(.int(Int64(limit)))
            return (try? db.query("SELECT \(Self.cols) FROM items \(whereSQL) ORDER BY pinned DESC, used DESC LIMIT ?", binds, Self.item)) ?? []
        }
    }

    public func count() -> Int { queue.sync { Int((try? db.query("SELECT COUNT(*) FROM items", [], { $0.int(0) }).first) ?? 0) } }

    public func payload(_ id: Int64) -> ClipPayload? {
        queue.sync {
            try? db.query("SELECT kind,text,rtf,html,image_file,files FROM items WHERE id=?", [.int(id)]) { r in
                ClipPayload(kind: ClipKind(rawValue: r.text(0) ?? "text") ?? .text, text: r.text(1), rtf: r.blob(2), html: r.blob(3),
                            imageFile: r.text(4),
                            files: (r.text(5)).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
            }.first
        }
    }
}
