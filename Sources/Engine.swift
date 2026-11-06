import Foundation
import SwiftUI

/// Watches the call log, decides, asks or files, and keeps what the window shows.
@MainActor
final class Engine: ObservableObject {
    let settings: Settings
    let store: Store
    let notifier: Notifier
    let filer = Filer()
    let demo: Bool

    @Published var access = "unknown"          // ok, denied, unknown
    @Published var lastCheck: Date?
    @Published var waiting: [Call] = []
    @Published var recent: [Call] = []
    @Published var ignored: [String] = []
    @Published var repeatCallers: [(number: String, calls: Int, last: Double)] = []
    @Published var days: [(date: Date, calls: Int, filed: Int)] = []
    @Published var stats = (unknown: 0, filed: 0, ignored: 0, waiting: 0)
    @Published var filing: Set<String> = []    // uids being filed right now
    @Published var lastProblem = ""
    @Published var testOutcome = ""            // what the last test question showed

    static let spamName = try! NSRegularExpression(pattern: "spam|scam|fraud|telemarket|robo|nuisance|junk", options: .caseInsensitive)

    init(home: String, demo: Bool) {
        self.demo = demo
        settings = Settings(path: home + "/config.json")
        store = try! Store(path: home + "/state.db")
        notifier = Notifier(settings: settings, store: store)
        notifier.onAnswer = { [weak self] choice, uid in
            Task { await self?.answer(choice, uid: uid) }
        }
        refresh()
    }

    func start() {
        guard !demo else { access = "ok"; lastCheck = Date().addingTimeInterval(-22); return }
        notifier.askPermission()
        notifier.startListening()
        Task {
            while true {
                await tick()
                try? await Task.sleep(nanoseconds: UInt64(settings.pollSeconds * 1_000_000_000))
            }
        }
    }

    func likely(_ call: Call) -> Bool {
        (call.reports ?? 0) >= settings.likelyReports ||
            Engine.spamName.firstMatch(in: call.callerName, range: NSRange(call.callerName.startIndex..., in: call.callerName)) != nil
    }

    func summary(_ call: Call) -> [String] {
        let f = DateFormatter(); f.dateFormat = "EEE h:mm a"
        if call.isText {
            let preview = call.body.count > 160 ? String(call.body.prefix(160)) + "…" : call.body
            var lines = ["\(likely(call) ? "Likely spam text from" : "Text from unknown number") \(dashed(call.number))",
                         f.string(from: call.date), "“\(preview)”"]
            if let r = call.reports { lines.append("FCC complaints on file: \(r)") }
            return lines
        }
        var lines = ["\(likely(call) ? "Likely robocall" : "Unknown caller") \(dashed(call.number))",
                     "\(f.string(from: call.date)), \(call.answered ? "answered, \(Int(call.duration.rounded())) s" : "not answered")"]
        if !call.callerName.isEmpty { lines.append("Caller ID: \(call.callerName)") }
        if let r = call.reports { lines.append("FCC complaints on file: \(r)") }
        return lines
    }

    /// What happens to one call or text from an unknown number: skipped as a repeat, filed, scheduled, or asked about.
    private func decide(_ incoming: Call) async {
        var call = incoming
        guard let number = call.number else { return }
        if store.toldRecently(number, before: call.ts, window: settings.repeatWindowHours * 3600) { store.record(call, "repeat"); return }
        if call.reports == nil { call.reports = await FCCData.reportCount(number) }
        // A call the owner stayed on is never filed without asking: that may have been a real conversation.
        let talked = call.answered && call.duration >= 30
        if settings.autoFile, likely(call), !talked, settings.ready {
            if settings.graceMinutes > 0 {
                // Announce it and wait: the owner can stop it (2) or file at once (1). `ref` holds the filing time.
                let due = Date().addingTimeInterval(Double(settings.graceMinutes) * 60)
                let f = DateFormatter(); f.dateFormat = "h:mm a"
                let how = notifier.repliesByText
                    ? ["Reply 2 to stop and ignore this number", "Reply 1 to file now"] : ["Ignore the number to stop this."]
                store.record(call, "scheduled", ref: String(due.timeIntervalSince1970))
                do {
                    try await notifier.send((summary(call) + ["", "Filing an FCC complaint at \(f.string(from: due).lowercased())"] + how)
                        .joined(separator: "\n"), uid: call.uid)
                } catch { lastProblem = "Could not send a notification: \((error as? FilingError)?.message ?? error.localizedDescription)" }
            } else {
                store.record(call, "asked")
                refresh()
                await file(call)
            }
        } else {
            do {
                let how = notifier.repliesByText
                    ? ["Reply 1 to file an FCC complaint", "Reply 2 to ignore this number from now on"]
                    : ["File a complaint or ignore this number?"]
                try await notifier.send((summary(call) + [""] + how).joined(separator: "\n"), uid: call.uid)
                store.record(call, "asked")
            } catch {
                store.record(call, "unsent")
                lastProblem = "Could not send a notification: \((error as? FilingError)?.message ?? error.localizedDescription)"
            }
        }
    }

    /// For checking the text rules against recent history: how the last `days` days of texts would be sorted. Sends and files nothing.
    func previewTexts(days: Double) throws -> String {
        let since = Date().timeIntervalSince1970 - days * 86400
        let (texts, _) = try TextLog.incoming(after: 0)
        let recent = texts.filter { $0.ts > since }
        let own = Set([digits10(settings.me["phone"]), digits10(notifier.handle)].compactMap { $0 })
        let known = try CallLog.contactNumbers().union(CallLog.dialedNumbers()).union(TextLog.writtenTo()).union(store.ignored()).union(own)
        var counts = ["not a 10 digit number": 0, "known sender": 0, "sign-in code": 0, "empty": 0]
        var unknown: [String: (Int, Bool)] = [:]
        for t in recent {
            guard let n = t.number else { counts["not a 10 digit number"]! += 1; continue }
            if known.contains(n) { counts["known sender"]! += 1; continue }
            if t.body.isEmpty { counts["empty"]! += 1; continue }
            if TextLog.looksLikeCode(t.body) { counts["sign-in code"]! += 1; continue }
            unknown[n] = ((unknown[n]?.0 ?? 0) + 1, (unknown[n]?.1 ?? false) || likely(t))
        }
        var out = ["\(recent.count) texts in \(Int(days)) days"] + counts.sorted { $0.key < $1.key }.map { "  skipped, \($0.key): \($0.value)" }
        out.append("  from unknown numbers: \(unknown.values.map(\.0).reduce(0, +)) texts, \(unknown.count) senders, \(unknown.values.filter(\.1).count) marked as junk by the phone")
        return out.joined(separator: "\n")
    }

    /// New text messages from numbers the owner does not know.
    private func checkTexts() async throws {
        guard let last = Int(store.get("text_rowid") ?? "") else {
            store.set("text_rowid", String(try TextLog.newestRow()))   // start from now, not from old messages
            return
        }
        let (texts, newest) = try TextLog.incoming(after: last)
        store.set("text_rowid", String(newest))
        let fresh = texts.filter { !store.seen($0.uid) }
        if fresh.isEmpty { return }
        let own = Set([digits10(settings.me["phone"]), digits10(notifier.handle)].compactMap { $0 })
        let known = try CallLog.contactNumbers().union(CallLog.dialedNumbers()).union(TextLog.writtenTo()).union(store.ignored()).union(own)
        for text in fresh {
            guard let number = text.number, !known.contains(number), !text.body.isEmpty, !TextLog.looksLikeCode(text.body) else {
                var skipped = text
                skipped.body = ""   // keep nothing of messages that are none of Spamurai's business
                store.record(skipped, text.number == nil ? "no-number" : "known")
                continue
            }
            await decide(text)
        }
    }

    // MARK: The watch loop

    func tick() async {
        let now = Date().timeIntervalSince1970
        do {
            let after = Double(store.get("watermark") ?? "") ?? now
            let new = try CallLog.incoming(since: after)
            if let newest = new.map(\.ts).max() { store.set("watermark", String(newest)) }
            else if store.get("watermark") == nil { store.set("watermark", String(now)) }
            access = "ok"
            let todo = new.filter { !store.seen($0.uid) }
            let retry = store.calls(where: "status='unsent'")
            if !todo.isEmpty || !retry.isEmpty {
                let known = try CallLog.contactNumbers().union(CallLog.dialedNumbers()).union(store.ignored())
                for call in retry + todo.filter({ $0.number != nil && !known.contains($0.number!) }) { await decide(call) }
                for call in todo where !store.seen(call.uid) { store.record(call, call.number == nil ? "no-number" : "known") }
            }
            if settings.watchTexts { try await checkTexts() }
            // Likely robocalls and spam texts whose waiting time is over.
            for call in store.calls(where: "status='scheduled'") where (Double(call.ref ?? "") ?? 0) <= now {
                var due = call
                due.ref = nil
                await file(due)
            }
        } catch is NoAccess {
            access = "denied"
        } catch {
            lastProblem = "\(error)"
        }
        lastCheck = Date()
        store.set("last_poll", String(now))
        refresh()
    }

    // MARK: Answers and filing

    /// 1 files, 2 ignores. From a notification button or the window (uid), or a typed reply (the newest open question).
    /// A typed 1 or 2 only counts while a question from the last two days is open; otherwise it is left alone
    /// without a reply, so other notes in the same thread never trigger anything.
    func answer(_ choice: String, uid: String? = nil) async {
        let open: [Call]
        if let uid { open = store.calls(where: "uid=? and status in ('asked','scheduled','link')", [uid]) }
        else { open = store.calls(where: "status in ('asked','scheduled') and noted > ?", [Date().timeIntervalSince1970 - 2 * 86400], order: "noted") }
        guard let call = open.last else { return }
        if call.uid.hasPrefix("test-") { await finishTest(call, choice); return }
        if choice == "2" {
            store.ignore(call.number ?? "")
            refresh()
            if uid == nil { try? await notifier.send("Spamurai\nIgnoring \(dashed(call.number)) from now on.") }
        } else {
            await file(call)
        }
    }

    // MARK: Test question (Setup): proves that a question arrives and that the answer is heard, without filing or ignoring anything

    func sendTestQuestion() async -> String {
        let now = Date().timeIntervalSince1970
        for old in store.calls(where: "uid like 'test-%'") { store.forget(old.uid) }
        var call = Call(uid: "test-\(Int(now))", number: "8445550123", ts: now - 300, callerName: "Spamurai test")
        call.reports = 0
        let how = notifier.repliesByText ? "Reply 1 or 2 to check that Spamurai hears you." : "Press File or Ignore to check that Spamurai hears you."
        do {
            try await notifier.send("Spamurai test question\nNo real call is involved and nothing will be filed or ignored.\n\n\(how)", uid: call.uid)
        } catch { return (error as? FilingError)?.message ?? error.localizedDescription }
        store.record(call, "asked")
        refresh()
        return notifier.repliesByText ? "Sent. Reply 1 or 2 from your iPhone" : "Sent. Use the buttons on the notification"
    }

    private func finishTest(_ call: Call, _ choice: String) async {
        store.forget(call.uid)
        refresh()
        var result = "Spamurai test passed\nYour answer \(choice) arrived."
        if choice == "1" {
            // Fill the real form for the made-up call and stop before Submit.
            do { _ = try await filer.file(call, settings, submit: false); result += " The FCC form was filled in and not sent." }
            catch { result += " The practice run of the form failed: \((error as? FilingError)?.message ?? error.localizedDescription)." }
        } else {
            result += " Nothing was ignored."
        }
        testOutcome = result.replacingOccurrences(of: "Spamurai test passed\n", with: "Test passed. ")
        try? await notifier.send(result)
    }

    func file(_ call: Call) async {
        let number = dashed(call.number)
        guard settings.ready else {
            try? await notifier.send("Not filed for \(number)\nSetup is missing: \(settings.gaps.joined(separator: ", ")).")
            return
        }
        guard store.filedSince(Date().timeIntervalSince1970 - 3600) < settings.maxFilingsPerHour else {
            try? await notifier.send("Not filed for \(number)\nAlready filed \(settings.maxFilingsPerHour) in the last hour. Try again later.")
            return
        }
        filing.insert(call.uid)
        defer { filing.remove(call.uid); refresh() }
        do {
            let ref = try await filer.file(call, settings, submit: true)
            store.record(call, "filed", ref: ref)
            lastProblem = ""
            let left = store.calls(where: "status='asked'").count
            var call = call
            call.ref = nil
            try? await notifier.send("Filed: \(Filer.subject(call))\n" + (ref == "accepted" ? "The FCC accepted the complaint." : "FCC request \(ref).") +
                                     (left > 0 ? " \(left) still waiting." : ""))
        } catch {
            let why = (error as? FilingError)?.message ?? error.localizedDescription
            store.record(call, "link")
            lastProblem = "Could not file for \(number): \(why)"
            try? await notifier.send("Could not file for \(number)\n\(why). Open Spamurai to try again or file it by hand.")
        }
    }

    func stopIgnoring(_ number: String) { store.stopIgnoring(number); refresh() }

    // MARK: What the window shows

    func refresh() {
        let now = Date().timeIntervalSince1970, since = now - 30 * 86400
        let shown = store.calls(where: "status not in \(Store.hidden)", order: "ts desc limit 200")
        recent = Array(shown.prefix(80))
        waiting = shown.filter { ["asked", "scheduled", "link"].contains($0.status) }.reversed()
        ignored = store.ignored()
        let month = shown.filter { $0.ts > since }
        stats = (month.count, month.filter { $0.status == "filed" }.count, month.filter { $0.status == "ignored" }.count,
                 shown.filter { $0.status == "asked" || $0.status == "scheduled" }.count)
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        days = (0..<30).reversed().map { back in
            let day = cal.date(byAdding: .day, value: -back, to: today)!
            let calls = month.filter { cal.isDate($0.date, inSameDayAs: day) }
            return (day, calls.count, calls.filter { $0.status == "filed" }.count)
        }
        var counts: [String: (calls: Int, last: Double)] = [:]
        for c in shown {
            guard let n = c.number else { continue }
            let old = counts[n] ?? (0, 0)
            counts[n] = (old.calls + 1, max(old.last, c.ts))
        }
        var repeats: [(number: String, calls: Int, last: Double)] = []
        for (n, v) in counts where v.calls > 1 { repeats.append((n, v.calls, v.last)) }
        repeats.sort { a, b in a.calls != b.calls ? a.calls > b.calls : a.last > b.last }
        repeatCallers = Array(repeats.prefix(8))
    }

    var running: Bool { demo || (lastCheck.map { Date().timeIntervalSince($0) < settings.pollSeconds * 3 + 30 } ?? false) }
}
