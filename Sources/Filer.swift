import AppKit
import WebKit

struct FilingError: Error { let message: String }

/// Files one complaint through the FCC's own web form in a system web view, the way a person would in Safari:
/// the form opens with the call's facts filled in, the owner's details are typed into it, the attestation box is
/// ticked and Submit is pressed. If the site shows a check that needs a person, filing stops and says so.
@MainActor
final class Filer: NSObject, WKNavigationDelegate {
    static let form = "https://consumercomplaints.fcc.gov/hc/en-us/requests/new"
    private var web: WKWebView?
    private var window: NSWindow?
    private var busy = false

    static func description(_ call: Call) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        var text = "Unwanted call to my cell phone from \(dashed(call.number)) on \(f.string(from: call.date))."
        text += call.answered ? " I answered; the call lasted \(Int(call.duration.rounded())) seconds." : " I did not answer."
        return text
    }

    /// The form address with everything that is not personal filled in through the form's own tf_ parameters.
    /// With `personal`, the owner's details are included too (used for the link a person opens by hand).
    static func url(_ call: Call, _ s: Settings, sworn: Bool) -> URL {
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter(); time.dateFormat = "h:mm a"
        var q: [(String, String)] = [
            ("ticket_form_id", "39744"),
            ("tf_subject", "Robocall \(dashed(call.number))"),
            ("tf_description", description(call)),
            ("tf_22619354", "telemarketing_phone"),
            ("tf_360000167206", "phone_unwanted_calls_all_other_unwanted_calls"),
            ("tf_22781220", "wireless_phone"),
            ("tf_22659804", s.me["phone_type"] == "business" ? "business_type_location" : "residential_personal_phone_type_location"),
            ("tf_22591154", day.string(from: call.date)),
            ("tf_22732340", time.string(from: call.date).lowercased()),
            ("tf_22787920", "yes_caller_id_information"),
            ("tf_22659864", dashed(call.number)),
            ("tf_22636844", "no_filing_on_behalf"),
            ("tf_22625574", "\(s.me["gave_permission"] ?? "no")_permission_to_call"),
            ("tf_22787860", "\(s.me["on_do_not_call_list"] ?? "uncertain")_do_not_call_list"),
        ]
        if !call.callerName.isEmpty { q.append(("tf_22659874", call.callerName)) }
        if let state = s.me["state"], !state.isEmpty {
            q.append(("tf_22540114", state.lowercased().replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: " ", with: "_")))
        }
        if sworn {   // the owner's standing answers about the call
            let a = s.answers
            q.append(("tf_22787840", a["call_type"] == "live" ? "live_voice_type_of_call_telemarketing" : "prerecorded_voice_type_of_call_telemarketing"))
            q.append(("tf_22625554", "\(a["advertised"] ?? "no")_telemarketing_services"))
            q.append(("tf_22630454", "\(a["name_given"] ?? "uncertain")_advertiser_business_name_provided"))
            q.append(("tf_52026458923796", "\(a["imposter"] ?? "uncertain")_imposter"))
            if a["advertised"] == "yes" {
                q += [("tf_360046689972", "unknown_services"), ("tf_22787930", "no_business_relationship_part_1"),
                      ("tf_22787940", "no_business_relationship_part_2"), ("tf_22629554", "no_personal_relationship")]
            }
        }
        var c = URLComponents(string: form)!
        c.queryItems = q.map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url!
    }

    private func js(_ script: String) async throws -> Any? {
        guard let web else { throw FilingError(message: "no web view") }
        return try await withCheckedThrowingContinuation { cont in
            web.evaluateJavaScript(script) { result, error in
                if let error { cont.resume(throwing: FilingError(message: error.localizedDescription)) } else { cont.resume(returning: result) }
            }
        }
    }

    private func wait(_ seconds: Double, until condition: String) async throws -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let ok = try? await js(condition) as? Bool, ok { return true }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }

    /// Shows the web view, for a check that needs a person or for watching a filing.
    func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }

    private func prepare() {
        if web != nil { return }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 900))
        view.navigationDelegate = self
        let w = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "FCC complaint form"
        w.isReleasedWhenClosed = false
        w.contentView = view
        web = view
        window = w
    }

    /// Fills the form and, when `submit` is true, sends it. Returns the FCC request number, or "accepted" when the site gives none.
    func file(_ call: Call, _ s: Settings, submit: Bool) async throws -> String {
        while busy { try await Task.sleep(nanoseconds: 300_000_000) }
        busy = true
        defer { busy = false }
        do { return try await run(call, s, submit: submit) } catch {
            await snapshot()   // keep a picture of the page for working out what went wrong
            throw error
        }
    }

    /// Saves what the form looked like to ~/Library/Logs/Callwatch/last-failure.png.
    private func snapshot() async {
        guard let web else { return }
        let dir = NSHomeDirectory() + "/Library/Logs/Callwatch"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let image: NSImage? = await withCheckedContinuation { cont in
            web.takeSnapshot(with: nil) { img, _ in cont.resume(returning: img) }
        }
        if let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir + "/last-failure.png"))
        }
        let where_ = web.url?.absoluteString.components(separatedBy: "?").first ?? ""
        let title = (try? await js("document.title") as? String) ?? ""
        try? "\(Date()) at \(where_) title \(title)\n".write(toFile: dir + "/last-failure.txt", atomically: true, encoding: .utf8)
    }

    private func run(_ call: Call, _ s: Settings, submit: Bool) async throws -> String {
        prepare()
        guard let web else { throw FilingError(message: "no web view") }
        web.load(URLRequest(url: Filer.url(call, s, sworn: true)))

        let subject = "Robocall \(dashed(call.number))"
        let loaded = try await wait(45, until: "(document.querySelector('[name=\"request[subject]\"]')||{}).value === \(quote(subject)) && !!document.querySelector('[name=\"request[custom_fields][22625624]\"]')")
        if !loaded {
            let title = (try? await js("document.title") as? String) ?? ""
            if title.contains("Just a moment") || title.isEmpty {
                throw FilingError(message: "the FCC site is asking for a browser check")
            }
            throw FilingError(message: "the FCC form did not load (\(title))")
        }

        let phone = dashed(s.me["phone"])
        let text: [(String, String)] = [
            ("request[anonymous_requester_email]", s.me["email"] ?? ""),
            ("request[custom_fields][22539594]", s.me["first_name"] ?? ""),
            ("request[custom_fields][22704720]", s.me["last_name"] ?? ""),
            ("request[custom_fields][22554824]", s.me["address1"] ?? ""),
            ("request[custom_fields][22718270]", s.me["address2"] ?? ""),
            ("request[custom_fields][22554844]", s.me["city"] ?? ""),
            ("request[custom_fields][22540124]", s.me["zip"] ?? ""),
            ("request[custom_fields][22625614]", phone),
            ("request[custom_fields][22615094]", phone),
        ]
        let pairs = "[" + text.filter { !$0.1.isEmpty }.map { "[\(quote($0.0)), \(quote($0.1))]" }.joined(separator: ",") + "]"
        // React keeps its own copy of each field, so values are set through the native setter and announced with events.
        let fill = """
        (() => {
          const bad = [];
          for (const [name, value] of \(pairs)) {
            const el = document.querySelector('[name="' + name + '"]');
            if (!el) { bad.push(name); continue; }
            const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            el.dispatchEvent(new Event('blur', { bubbles: true }));
            if (el.value !== value) bad.push(name);
          }
          const box = document.querySelector('input[type="checkbox"][name="request[custom_fields][22625624]"]');
          if (!box) bad.push('attest'); else if (!box.checked) box.click();
          if (box && !box.checked) bad.push('attest');
          return bad.join(', ');
        })()
        """
        let bad = (try await js(fill) as? String) ?? "unknown"
        if !bad.isEmpty { throw FilingError(message: "could not fill: \(bad)") }
        try await Task.sleep(nanoseconds: 600_000_000)

        // Everything the form requires must hold a value before Submit is pressed.
        let required = ["request[anonymous_requester_email]", "request[subject]"] +
            ["22619354", "360000167206", "22781220", "22659804", "22625614", "22787840", "22625554", "22625574", "22630454",
             "52026458923796", "22539594", "22704720", "22554824", "22554844", "22540114", "22540124", "22615094", "22636844"]
            .map { "request[custom_fields][\($0)]" }
        let check = "(() => \(jsArray(required)).filter(n => { const e = [...document.querySelectorAll('[name=\"' + n + '\"]')].pop(); return !e || !e.value; }).join(', '))()"
        let empty = (try await js(check) as? String) ?? "unknown"
        if !empty.isEmpty { throw FilingError(message: "the form is missing: \(empty.replacingOccurrences(of: "request[custom_fields]", with: ""))") }
        if !submit { return "filled, not sent" }

        let pressed = try await js("(() => { const f = document.querySelector('[name=\"request[subject]\"]').closest('form'); const b = f.querySelector('button[type=submit], input[type=submit]'); if (!b) return false; b.click(); return true; })()") as? Bool
        if pressed != true { throw FilingError(message: "no Submit button on the form") }

        let end = Date().addingTimeInterval(60)
        while Date() < end {
            try await Task.sleep(nanoseconds: 700_000_000)
            let url = web.url?.absoluteString ?? ""
            if !url.contains("/requests/new"), !web.isLoading || url.contains("/requests/") {
                if let r = url.range(of: #"/requests/(\d+)"#, options: .regularExpression) {
                    return String(url[r]).replacingOccurrences(of: "/requests/", with: "")
                }
                let title = (try? await js("document.title") as? String) ?? ""
                if title.contains("Just a moment") { throw FilingError(message: "the FCC site is asking for a browser check") }
                if url.contains("/signin") { throw FilingError(message: "the FCC site asked for a sign-in") }
                return "accepted"
            }
            // Still on the form: look for the form's own error messages.
            let errors = (try? await js("[...document.querySelectorAll('[role=alert], [data-garden-id=\"forms.input_message\"][data-validation=\"error\"], .notification-error')].map(e => e.innerText.trim()).filter(Boolean).slice(0, 4).join('; ')") as? String) ?? ""
            if !errors.isEmpty { throw FilingError(message: "the form answered: \(errors)") }
        }
        throw FilingError(message: "the form did not confirm within a minute")
    }

    private func quote(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
    }

    private func jsArray(_ a: [String]) -> String { String(data: try! JSONSerialization.data(withJSONObject: a), encoding: .utf8)! }
}
