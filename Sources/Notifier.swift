import AppKit
import Foundation
import UserNotifications

/// Tells the owner about a call and takes the answer back.
/// imessage: an iMessage to the owner's own number; the owner replies 1 or 2 in that thread.
/// mac: a notification on this Mac with File and Ignore buttons.
/// none: nothing is sent; the owner opens Spamurai and answers there.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    let settings: Settings
    let store: Store
    var onAnswer: ((_ choice: String, _ uid: String?) -> Void)?
    private var pollTimer: Timer?
    private var lastChoice: (String, Date)?
    static var messagesDB: String { TextLog.path }

    init(settings: Settings, store: Store) {
        self.settings = settings
        self.store = store
        super.init()
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.setNotificationCategories([UNNotificationCategory(identifier: "CALL", actions: [
            UNNotificationAction(identifier: "1", title: "File complaint"),
            UNNotificationAction(identifier: "2", title: "Ignore number")], intentIdentifiers: [])])
    }

    func askPermission() { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }

    var repliesByText: Bool { settings.notifyKind == "imessage" }

    /// `uid` set means the message asks about that call, so a Mac notification carries the answer buttons.
    @MainActor
    func send(_ text: String, uid: String? = nil) async throws {
        if settings.notifyKind == "none" { return }
        if settings.notifyKind == "imessage" {
            try iMessage(text)
            return
        }
        let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
        let content = UNMutableNotificationContent()
        content.title = parts.first ?? "Spamurai"
        content.body = parts.count > 1 ? parts[1] : ""
        content.sound = .default
        if let uid { content.categoryIdentifier = "CALL"; content.userInfo = ["uid": uid] }
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let uid = response.notification.request.content.userInfo["uid"] as? String
        if ["1", "2"].contains(response.actionIdentifier) {
            await MainActor.run { onAnswer?(response.actionIdentifier, uid) }
        } else {
            await MainActor.run { NotificationCenter.default.post(name: .init("SpamuraiOpenWindow"), object: nil) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // MARK: iMessage

    /// Where the messages go: the owner's own cell number unless config.json names another iMessage address.
    var handle: String? {
        let own = settings.imessageTo.trimmingCharacters(in: .whitespaces)
        if own.contains("@") { return own }
        return (digits10(own) ?? digits10(settings.me["phone"])).map { "+1" + $0 }
    }

    /// The owner's conversation with themselves in Messages, when there is one.
    func selfThread() -> String? {
        guard let handle else { return nil }
        let key = digits10(handle) ?? handle
        return (try? DB(path: Notifier.messagesDB, readOnly: true))
            .flatMap { try? $0.rows("select guid from chat where chat_identifier like ? order by ROWID desc limit 1", ["%" + key]) }?
            .first?[0] as? String
    }

    /// Opens Messages on a new message to the owner's own address.
    func openSelfThread() {
        guard let handle, let url = URL(string: "imessage://" + (handle.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? handle)) else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    private func iMessage(_ text: String) throws {
        guard let handle else { throw FilingError(message: "no cell number in Setup to send the iMessage to") }
        let quote: (String) -> String = { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        // Messages can take minutes to list its accounts on a Mac with a long history, so the message goes straight
        // to the owner's existing conversation with themselves.
        guard let thread = selfThread() else {
            throw FilingError(message: "Send yourself one iMessage from this Mac first (Setup has a button), then try again")
        }
        let source = """
        with timeout of 45 seconds
            tell application "Messages" to send \(quote(text)) to chat id \(quote(thread))
        end timeout
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                throw FilingError(message: "macOS has not allowed Spamurai to send with Messages. Allow it in System Settings, Privacy & Security, Automation")
            }
            throw FilingError(message: "Messages could not send: \(error[NSAppleScript.errorMessage] as? String ?? "error \(code)")")
        }
    }

    /// New messages in the owner's thread with themselves that are exactly "1" or "2".
    private func pollReplies() {
        guard settings.notifyKind == "imessage", let digits = digits10(handle) ?? handle,
              let db = try? DB(path: Notifier.messagesDB, readOnly: true) else { return }
        guard let last = Int(store.get("imessage_rowid") ?? "") else {
            let top = (try? db.rows("select coalesce(max(ROWID), 0) from message"))?.first?[0] as? Int ?? 0
            store.set("imessage_rowid", String(top))
            return
        }
        let rows = (try? db.rows(
            "select m.ROWID, m.text, m.attributedBody from message m join chat_message_join j on j.message_id = m.ROWID " +
            "join chat c on c.ROWID = j.chat_id where m.ROWID > ? and c.chat_identifier like ? order by m.ROWID", [last, "%" + digits])) ?? []
        guard let newest = rows.last?[0] as? Int else { return }
        store.set("imessage_rowid", String(newest))
        for r in rows {
            let t = (messageText(r[1], r[2]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard t == "1" || t == "2" else { continue }
            // A message to yourself is stored twice (sent and received); count it once.
            if let (c, at) = lastChoice, c == t, Date().timeIntervalSince(at) < 20 { continue }
            lastChoice = (t, Date())
            onAnswer?(t, nil)
        }
    }

    /// Starts reading replies; safe to call again after the choice changes.
    func startListening() {
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.pollReplies() }
        }
    }
}
