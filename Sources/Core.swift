import Foundation
import SQLite3

// MARK: Phone numbers

func digits10(_ number: String?) -> String? {
    var d = (number ?? "").filter(\.isNumber)
    if d.count == 11, d.hasPrefix("1") { d.removeFirst() }
    guard d.count == 10, let first = d.first, first != "0", first != "1" else { return nil }
    return d
}

func dashed(_ number: String?) -> String {
    guard let d = digits10(number) else { return number ?? "" }
    let a = Array(d)
    return "\(String(a[0..<3]))-\(String(a[3..<6]))-\(String(a[6..<10]))"
}

// MARK: SQLite

struct DBError: Error { let message: String; let denied: Bool }

final class DB {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String, readOnly: Bool) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        if rc != SQLITE_OK {
            let err = error(rc)
            sqlite3_close(handle)
            throw err
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close(handle) }

    private func error(_ rc: Int32) -> DBError {
        let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
        // macOS answers a read it does not allow with "authorization denied" or "unable to open".
        return DBError(message: msg, denied: rc == SQLITE_AUTH || rc == SQLITE_CANTOPEN || rc == SQLITE_PERM)
    }

    @discardableResult
    func rows(_ sql: String, _ binds: [Any?] = []) throws -> [[Any?]] {
        var st: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &st, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
        defer { sqlite3_finalize(st) }
        for (i, value) in binds.enumerated() {
            let n = Int32(i + 1)
            switch value {
            case nil: sqlite3_bind_null(st, n)
            case let v as Int: sqlite3_bind_int64(st, n, Int64(v))
            case let v as Double: sqlite3_bind_double(st, n, v)
            case let v as Bool: sqlite3_bind_int64(st, n, v ? 1 : 0)
            case let v as String: sqlite3_bind_text(st, n, v, -1, DB.transient)
            default: sqlite3_bind_text(st, n, "\(value!)", -1, DB.transient)
            }
        }
        var out: [[Any?]] = []
        while true {
            let step = sqlite3_step(st)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw error(step) }
            var row: [Any?] = []
            for c in 0..<sqlite3_column_count(st) {
                switch sqlite3_column_type(st, c) {
                case SQLITE_INTEGER: row.append(Int(sqlite3_column_int64(st, c)))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(st, c))
                case SQLITE_NULL: row.append(nil)
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(st, c))
                    let data = sqlite3_column_blob(st, c).map { Data(bytes: $0, count: n) } ?? Data()
                    row.append(data)
                default: row.append(sqlite3_column_text(st, c).map { String(cString: $0) })
                }
            }
            out.append(row)
        }
        return out
    }
}

func asDouble(_ v: Any?) -> Double { (v as? Double) ?? Double(v as? Int ?? 0) }

/// A text column that some rows store as a blob.
func asString(_ v: Any?) -> String? { (v as? String) ?? (v as? Data).flatMap { String(data: $0, encoding: .utf8) } }

// MARK: A call

struct Call: Identifiable, Equatable {
    var uid: String
    var number: String?          // 10 digits, nil for blocked or foreign numbers
    var ts: Double
    var duration: Double = 0
    var answered = false
    var callerName = ""
    var reports: Int?
    var status = ""
    var ref: String?
    var kind = "call"            // call or text
    var body = ""                // what a text message said
    var id: String { uid }
    var isText: Bool { kind == "text" }
    var date: Date { Date(timeIntervalSince1970: ts) }
}

// MARK: The call log macOS syncs from the iPhone

struct NoAccess: Error {}

enum CallLog {
    static let appleEpoch = 978_307_200.0   // Core Data dates count from 2001-01-01
    static var path = NSHomeDirectory() + "/Library/Application Support/CallHistoryDB/CallHistory.storedata"
    static var contactsRoot = NSHomeDirectory() + "/Library/Application Support/AddressBook"

    private static func open(_ path: String) throws -> DB {
        do {
            let db = try DB(path: path, readOnly: true)
            try db.rows("select 1 from sqlite_master limit 1")
            return db
        } catch let e as DBError where e.denied { throw NoAccess() }
    }

    /// Incoming phone calls (not FaceTime) newer than `since`, oldest first.
    static func incoming(since: Double) throws -> [Call] {
        let db = try open(path)
        let rows = try db.rows(
            "select ZUNIQUE_ID, ZADDRESS, ZDATE + ?, ZDURATION, ZANSWERED, ZNAME from ZCALLRECORD " +
            "where ZORIGINATED = 0 and ZCALLTYPE = 1 and ZDATE + ? > ? order by ZDATE", [appleEpoch, appleEpoch, since])
        return rows.map { r in
            Call(uid: r[0] as? String ?? UUID().uuidString, number: digits10(asString(r[1])), ts: asDouble(r[2]),
                 duration: asDouble(r[3]), answered: (r[4] as? Int ?? 0) != 0,
                 callerName: (r[5] as? String ?? "").trimmingCharacters(in: .whitespaces))
        }
    }

    /// Every number the owner has called: a caller you phone yourself is not a robocaller.
    static func dialedNumbers() throws -> Set<String> {
        let db = try open(path)
        return Set(try db.rows("select distinct ZADDRESS from ZCALLRECORD where ZORIGINATED = 1").compactMap { digits10(asString($0[0])) })
    }

    static func contactNumbers() throws -> Set<String> {
        var files = [contactsRoot + "/AddressBook-v22.abcddb"]
        let sources = contactsRoot + "/Sources"
        do {
            for dir in try FileManager.default.contentsOfDirectory(atPath: sources) {
                files.append("\(sources)/\(dir)/AddressBook-v22.abcddb")
            }
        } catch let e as NSError where e.code == NSFileReadNoPermissionError { throw NoAccess() } catch {}
        var found = Set<String>()
        for file in files where FileManager.default.fileExists(atPath: file) {
            let db = try open(file)
            if let rows = try? db.rows("select ZFULLNUMBER from ZABCDPHONENUMBER") {
                for r in rows { if let d = digits10(r[0] as? String) { found.insert(d) } }
            }
        }
        return found
    }
}

// MARK: Text messages in the Mac's Messages history

/// The text of a message row. Newer macOS versions keep it only inside the `attributedBody` archive.
func messageText(_ text: Any?, _ body: Any?) -> String? {
    if let t = text as? String { return t }
    guard let data = body as? Data, let marker = data.range(of: Data("NSString".utf8)) else { return nil }
    var i = marker.upperBound
    while i < data.endIndex, data[i] != 0x2B { i += 1 }      // '+' introduces the string
    guard i + 1 < data.endIndex else { return nil }
    var length = Int(data[i + 1]); i += 2
    if length == 0x81, i + 1 < data.endIndex { length = Int(data[i]) | Int(data[i + 1]) << 8; i += 2 }
    guard i + length <= data.endIndex else { return nil }
    return String(data: data[i..<(i + length)], encoding: .utf8)
}

enum TextLog {
    static var path = NSHomeDirectory() + "/Library/Messages/chat.db"

    private static func open() throws -> DB {
        do {
            let db = try DB(path: path, readOnly: true)
            try db.rows("select 1 from sqlite_master limit 1")
            return db
        } catch let e as DBError where e.denied { throw NoAccess() }
    }

    static func newestRow() throws -> Int {
        (try open().rows("select coalesce(max(ROWID), 0) from message").first?[0] as? Int) ?? 0
    }

    /// Text messages received one-to-one after message row `after`, oldest first, and the newest row seen.
    static func incoming(after: Int) throws -> (texts: [Call], newest: Int) {
        let rows = try open().rows(
            "select m.ROWID, m.guid, h.id, m.text, m.attributedBody, m.date / 1000000000.0 + 978307200, coalesce(m.is_spam, 0) " +
            "from message m join handle h on h.ROWID = m.handle_id " +
            "join chat_message_join j on j.message_id = m.ROWID join chat c on c.ROWID = j.chat_id " +
            "where m.ROWID > ? and m.is_from_me = 0 and m.item_type = 0 and coalesce(m.associated_message_type, 0) = 0 and c.style = 45 " +
            "order by m.ROWID", [after])
        let texts = rows.map { r in
            Call(uid: "text-" + (r[1] as? String ?? UUID().uuidString), number: digits10(r[2] as? String), ts: asDouble(r[5]),
                 callerName: (r[6] as? Int ?? 0) != 0 ? "Marked as junk" : "", kind: "text",
                 body: (messageText(r[3], r[4]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (texts, (rows.last?[0] as? Int) ?? after)
    }

    /// Every number the owner has written to: someone you text yourself is not a spammer.
    static func writtenTo() throws -> Set<String> {
        let rows = try open().rows("select distinct h.id from message m join handle h on h.ROWID = m.handle_id where m.is_from_me = 1")
        return Set(rows.compactMap { digits10($0[0] as? String) })
    }

    /// Sign-in and delivery codes come from numbers nobody has saved; they are not spam.
    static func looksLikeCode(_ body: String) -> Bool {
        body.range(of: #"\b\d{4,8}\b"#, options: .regularExpression) != nil &&
            body.range(of: "code|verif|passcode|one-time|otp|2fa|sign in|login|security", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

// MARK: Spamurai's own history

final class Store {
    let db: DB
    static let hidden = "('known','no-number')"   // contacts and blocked numbers are not shown

    init(path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        db = try DB(path: path, readOnly: false)
        try db.rows("create table if not exists meta (k text primary key, v text)")
        try db.rows("create table if not exists calls (uid text primary key, number text, ts real, answered int, duration real, " +
                    "reports int, status text, noted real, caller_name text default '', ref text)")
        try db.rows("create table if not exists ignored (number text primary key, added real)")
        let have = Set(try db.rows("pragma table_info(calls)").compactMap { $0[1] as? String })
        if !have.contains("kind") { try db.rows("alter table calls add column kind text default 'call'") }
        if !have.contains("body") { try db.rows("alter table calls add column body text default ''") }
        // 1 when no question was sent about it (caught up on after the Mac was away): a typed reply never applies to it.
        if !have.contains("quiet") { try db.rows("alter table calls add column quiet int default 0") }
    }

    func get(_ key: String) -> String? { (try? db.rows("select v from meta where k=?", [key]))?.first?[0] as? String }
    func set(_ key: String, _ value: String) { _ = try? db.rows("insert or replace into meta values (?,?)", [key, value]) }

    func seen(_ uid: String) -> Bool { !((try? db.rows("select 1 from calls where uid=?", [uid])) ?? []).isEmpty }

    func toldRecently(_ number: String, before ts: Double, window: Double) -> Bool {
        !((try? db.rows("select 1 from calls where number=? and status in ('asked','scheduled','filed','link') and ts > ? and ts < ? limit 1",
                        [number, ts - window, ts])) ?? []).isEmpty
    }

    func record(_ call: Call, _ status: String, ref: String? = nil, quiet: Bool = false) {
        _ = try? db.rows("insert or replace into calls (uid, number, ts, answered, duration, reports, status, noted, caller_name, ref, kind, body, quiet) " +
                         "values (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                         [call.uid, call.number, call.ts, call.answered, call.duration, call.reports, status,
                          Date().timeIntervalSince1970, call.callerName, ref, call.kind, call.body, quiet ? 1 : 0])
    }

    func calls(where clause: String, _ binds: [Any?] = [], order: String = "ts") -> [Call] {
        let rows = (try? db.rows("select uid, number, ts, answered, duration, caller_name, reports, status, ref, kind, body from calls " +
                                 "where \(clause) order by \(order)", binds)) ?? []
        return rows.map { r in
            Call(uid: r[0] as? String ?? "", number: r[1] as? String, ts: asDouble(r[2]), duration: asDouble(r[4]),
                 answered: (r[3] as? Int ?? 0) != 0, callerName: r[5] as? String ?? "", reports: r[6] as? Int,
                 status: r[7] as? String ?? "", ref: r[8] as? String, kind: r[9] as? String ?? "call", body: r[10] as? String ?? "")
        }
    }

    func ignore(_ number: String) {
        _ = try? db.rows("insert or replace into ignored values (?,?)", [number, Date().timeIntervalSince1970])
        _ = try? db.rows("update calls set status='ignored' where number=? and status in ('asked','scheduled','unsent','link')", [number])
    }

    func forget(_ uid: String) { _ = try? db.rows("delete from calls where uid=?", [uid]) }

    func stopIgnoring(_ number: String) { _ = try? db.rows("delete from ignored where number=?", [number]) }

    func ignored() -> [String] { ((try? db.rows("select number from ignored order by added desc")) ?? []).compactMap { $0[0] as? String } }

    func filedSince(_ ts: Double) -> Int {
        ((try? db.rows("select count(*) from calls where status='filed' and noted > ?", [ts]))?.first?[0] as? Int) ?? 0
    }
}

// MARK: FCC public complaint data

enum FCCData {
    /// Complaints that already name this caller ID, or nil when the lookup fails.
    static func reportCount(_ number: String) async -> Int? {
        var c = URLComponents(string: "https://opendata.fcc.gov/resource/3xyp-aqkj.json")!
        c.queryItems = [URLQueryItem(name: "$select", value: "count(*)"), URLQueryItem(name: "caller_id_number", value: dashed(number))]
        var req = URLRequest(url: c.url!, timeoutInterval: 15)
        req.setValue("Spamurai (personal)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let s = rows.first?["count"] as? String else { return nil }
        return Int(s)
    }
}
