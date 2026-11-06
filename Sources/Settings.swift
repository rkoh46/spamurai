import Foundation
import SwiftUI

/// The owner's settings, kept in ~/Library/Application Support/Callwatch/config.json.
final class Settings: ObservableObject {
    static let meKeys = ["first_name", "last_name", "email", "phone", "address1", "address2", "city", "state", "zip",
                         "gave_permission", "on_do_not_call_list", "phone_type"]
    static let requiredMe = ["first_name", "last_name", "email", "phone", "address1", "city", "state", "zip"]
    static let answerKeys = ["call_type", "advertised", "name_given", "imposter"]

    let path: String
    private var raw: [String: Any] = [:]

    @Published var me: [String: String] = ["gave_permission": "no", "on_do_not_call_list": "uncertain", "phone_type": "personal"]
    @Published var answers: [String: String] = [:]
    @Published var agreed = false          // the owner accepted that complaints carry the perjury statement
    @Published var autoFile = false        // file likely robocalls without asking
    @Published var graceMinutes = 30       // wait this long before filing a likely robocall, so the owner can stop it (0 = file at once)
    @Published var notifyKind = "imessage" // imessage (to the owner's own address), mac (a notification), or none (the owner checks the app)
    @Published var imessageTo = ""         // the owner's iMessage address when it is not the cell number (an Apple Account email, say)
    var pollSeconds = 60.0
    var repeatWindowHours = 24.0
    var likelyReports = 3
    var maxFilingsPerHour = 5

    init(path: String) {
        self.path = path
        load()
    }

    func load() {
        guard let data = FileManager.default.contents(atPath: path),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        raw = d
        for (k, v) in d["me"] as? [String: Any] ?? [:] { if let s = v as? String { me[k] = s } }
        for (k, v) in d["answers"] as? [String: Any] ?? [:] { if let s = v as? String { answers[k] = s } }
        agreed = d["agreed"] as? Bool ?? false
        autoFile = d["auto_file_likely"] as? Bool ?? false
        graceMinutes = (d["grace_minutes"] as? NSNumber)?.intValue ?? 30
        let n = d["notify"] as? [String: Any] ?? [:]
        let kind = n["kind"] as? String ?? ""
        notifyKind = ["mac", "none"].contains(kind) ? kind : "imessage"   // earlier versions had other channels
        imessageTo = n["imessage_to"] as? String ?? ""
        pollSeconds = (d["poll_seconds"] as? NSNumber)?.doubleValue ?? 60
        repeatWindowHours = (d["repeat_window_hours"] as? NSNumber)?.doubleValue ?? 24
        likelyReports = (d["likely_reports"] as? NSNumber)?.intValue ?? 3
        maxFilingsPerHour = (d["max_filings_per_hour"] as? NSNumber)?.intValue ?? 5
    }

    func save() {
        var d = raw
        var m = d["me"] as? [String: Any] ?? [:]
        for (k, v) in me { m[k] = v }
        d["me"] = m
        d["answers"] = answers
        d["agreed"] = agreed
        d["auto_file_likely"] = autoFile
        d["grace_minutes"] = graceMinutes
        var n = d["notify"] as? [String: Any] ?? [:]
        n["kind"] = notifyKind
        n["imessage_to"] = imessageTo.trimmingCharacters(in: .whitespaces)
        d["notify"] = n
        raw = d
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let tmp = path + ".tmp"
        FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600])
        _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
    }

    /// What still has to be filled in before a complaint can be filed.
    var gaps: [String] {
        let names = ["first_name": "first name", "last_name": "last name", "email": "email", "phone": "cell number",
                     "address1": "street address", "city": "city", "state": "state", "zip": "zip code",
                     "call_type": "type of call", "advertised": "whether the calls advertise something",
                     "name_given": "whether a business name is given", "imposter": "whether the caller impersonates someone"]
        var out = Settings.requiredMe.filter { (me[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.map { names[$0]! }
        if !(me["phone"] ?? "").isEmpty, digits10(me["phone"]) == nil, !out.contains("cell number") { out.append("a 10 digit cell number") }
        out += Settings.answerKeys.filter { (answers[$0] ?? "").isEmpty }.map { names[$0]! }
        if !agreed { out.append("your agreement to the perjury statement") }
        return out
    }

    var ready: Bool { gaps.isEmpty }

    func bindMe(_ key: String) -> Binding<String> {
        Binding(get: { self.me[key] ?? "" }, set: { self.me[key] = $0; self.save() })
    }

    func bindAnswer(_ key: String) -> Binding<String> {
        Binding(get: { self.answers[key] ?? "" }, set: { self.answers[key] = $0; self.save() })
    }
}
