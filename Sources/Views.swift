import Charts
import ServiceManagement
import SwiftUI

// Colour carries meaning here: green is filed, orange needs you, red is ignored or failed, blue is neutral information.
// The app's own tint is the amber of its icon.
let brand = Color(red: 1.0, green: 0.58, blue: 0.0)
private let hairline = Color.primary.opacity(0.08)

/// A symbol on a coloured rounded square, the way System Settings shows its sections.
struct IconTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 28
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white))
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(hairline))
    }
}

private struct Tag: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private func relative(_ date: Date) -> String {
    let s = max(0, Int(Date().timeIntervalSince(date)))
    return s < 90 ? "\(s) s ago" : s < 5400 ? "\(s / 60) min ago" : s < 172_800 ? "\(s / 3600) h ago" : "\(s / 86400) days ago"
}

private func whenText(_ date: Date) -> String {
    let cal = Calendar.current, t = DateFormatter(), d = DateFormatter()
    t.dateFormat = "h:mm a"
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
    d.dateFormat = days < 7 ? "EEEE" : "MMM d"
    return "\(days == 0 ? "Today" : days == 1 ? "Yesterday" : d.string(from: date)), \(t.string(from: date).lowercased())"
}

private func clock(_ ts: Double) -> String {
    let f = DateFormatter(); f.dateFormat = "h:mm a"
    return f.string(from: Date(timeIntervalSince1970: ts)).lowercased()
}

private let numberFont = Font.system(.body, design: .rounded).weight(.semibold)

enum Page: String, CaseIterable, Identifiable {
    case calls = "Calls", ignored = "Ignored", setup = "Setup"
    var id: String { rawValue }
    var title: String { self == .calls ? "Calls & Texts" : rawValue }
    var symbol: String { self == .calls ? "phone.arrow.down.left.fill" : self == .ignored ? "hand.raised.fill" : "gearshape.fill" }
    var color: Color { self == .calls ? .green : self == .ignored ? .red : .gray }
}

struct RootView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var settings: Settings
    @State var page: Page

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: Binding(get: { page }, set: { page = $0 ?? .calls })) { p in
                Label { Text(p.title) } icon: { IconTile(symbol: p.symbol, color: p.color, size: 22) }
                    .badge(p == .calls ? engine.stats.waiting : p == .ignored ? engine.ignored.count : 0)
                    .padding(.vertical, 2)
                    .tag(p)
            }
            .safeAreaInset(edge: .bottom) { status.padding(16).frame(maxWidth: .infinity, alignment: .leading) }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            switch page {
            case .calls: CallsView(openSetup: { page = .setup })
            case .ignored: IgnoredView()
            case .setup: SetupView()
            }
        }
        .onAppear { if !settings.ready { page = .setup } }
    }

    private var status: some View {
        let (symbol, color, text): (String, Color, String) =
            !engine.running ? ("xmark.circle.fill", .red, "Not running") :
            engine.access == "denied" ? ("lock.circle.fill", .red, "No access to calls") :
            !settings.ready ? ("exclamationmark.circle.fill", .orange, "Setup not finished") :
            ("checkmark.circle.fill", .green, "Watching your calls")
        return HStack(spacing: 8) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(text).font(.callout.weight(.medium))
                if let c = engine.lastCheck, engine.running {
                    TimelineView(.periodic(from: .now, by: 10)) { _ in
                        Text("Checked \(relative(c))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }
}

// MARK: Calls

struct CallsView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var settings: Settings
    var openSetup: () -> Void
    @State private var askIgnore: Call?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if engine.access == "denied" {
                    notice("lock.fill", .red, "Spamurai can't read your calls",
                           "In Full Disk Access, switch Spamurai on, then quit and reopen it.", "Open Full Disk Access") { openFullDiskAccess() }
                }
                if !settings.ready {
                    notice("exclamationmark.triangle.fill", .orange, "Nothing can be filed yet", "Missing: \(settings.gaps.joined(separator: ", ")).", "Finish Setup", openSetup)
                }
                if !engine.lastProblem.isEmpty {
                    notice("xmark.octagon.fill", .red, "A filing did not go through", engine.lastProblem, "Show Form") { engine.filer.showWindow() }
                }
                stats.padding(.top, 20)
                chart.padding(.top, 12)
                if !engine.waiting.isEmpty {
                    header("Needs your answer")
                    Card { ForEach(Array(engine.waiting.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Divider().padding(.leading, 58) }
                        waitingRow(c)
                    } }
                }
                header("Recent calls and texts")
                if engine.recent.isEmpty {
                    Card { HStack(spacing: 14) {
                        IconTile(symbol: "phone.arrow.down.left.fill", color: .green, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Nothing from unknown numbers yet").font(.headline)
                            Text("Calls and texts from numbers that aren't in your contacts show up here about a minute after they reach your iPhone.")
                                .foregroundStyle(.secondary)
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    Card { ForEach(Array(engine.recent.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Divider().padding(.leading, 50) }
                        recentRow(c)
                    } }
                }
                if !engine.repeatCallers.isEmpty {
                    header("Repeat callers")
                    Card { ForEach(Array(engine.repeatCallers.enumerated()), id: \.offset) { i, r in
                        if i > 0 { Divider().padding(.leading, 50) }
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill").font(.title2).foregroundStyle(.purple)
                            Text(dashed(r.number)).font(numberFont).monospacedDigit().textSelection(.enabled)
                            Spacer()
                            Text("last \(relative(Date(timeIntervalSince1970: r.last)))").foregroundStyle(.secondary)
                            Tag(text: "\(r.calls) calls", color: .purple)
                        }.padding(.horizontal, 16).padding(.vertical, 9)
                    } }
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 32)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(brand)
        .navigationTitle("Calls & Texts")
        .alert("Ignore \(dashed(askIgnore?.number))?", isPresented: Binding(get: { askIgnore != nil }, set: { if !$0 { askIgnore = nil } }), presenting: askIgnore) { call in
            Button("Ignore Number", role: .destructive) { Task { await engine.answer("2", uid: call.uid) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Spamurai will stop asking about this number and will never report it. You can undo this on the Ignored page.")
        }
    }

    private func header(_ s: String) -> some View {
        Text(s).font(.title3.weight(.semibold)).padding(.top, 28).padding(.bottom, 10)
    }

    private func notice(_ symbol: String, _ color: Color, _ title: String, _ detail: String, _ button: String, _ action: @escaping () -> Void) -> some View {
        Card { HStack(spacing: 12) {
            IconTile(symbol: symbol, color: color, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(button, action: action)
        }.padding(.horizontal, 14).padding(.vertical, 12) }.padding(.top, 16)
    }

    private var stats: some View {
        HStack(spacing: 12) {
            stat("phone.arrow.down.left.fill", .blue, engine.stats.unknown, "Unknown numbers", "calls and texts, 30 days")
            stat("checkmark.seal.fill", .green, engine.stats.filed, "Complaints filed", "last 30 days")
            stat("hand.raised.fill", .red, engine.stats.ignored, "Ignored", "last 30 days")
            stat("clock.fill", .orange, engine.stats.waiting, "Need your answer", "right now")
        }
    }

    private func stat(_ symbol: String, _ color: Color, _ n: Int, _ label: String, _ sub: String) -> some View {
        Card { VStack(alignment: .leading, spacing: 10) {
            IconTile(symbol: symbol, color: color, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(n)").font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                Text(label).font(.callout.weight(.medium))
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading) }
    }

    private var chart: some View {
        Card { VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Calls and texts per day").font(.headline)
                Spacer()
                Label("Filed", systemImage: "square.fill").foregroundStyle(.green).font(.caption)
                Label("Not filed", systemImage: "square.fill").foregroundStyle(.blue.opacity(0.75)).font(.caption)
            }.labelStyle(.titleAndIcon)
            Chart {
                ForEach(Array(engine.days.enumerated()), id: \.offset) { _, d in
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Count", d.filed)).foregroundStyle(Color.green.gradient)
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Count", d.calls - d.filed)).foregroundStyle(Color.blue.opacity(0.6))
                }
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .frame(height: 110)
        }.padding(14) }
    }

    private func heard(_ c: Call) -> String { c.isText ? "text message" : c.answered ? "answered, \(Int(c.duration.rounded())) s" : "not answered" }

    /// The number with a small phone or message symbol, and what a text said underneath.
    private func title(_ c: Call, flagged: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: c.isText ? "message.fill" : "phone.fill").font(.caption).foregroundStyle(c.isText ? Color.green : .secondary)
            Text(dashed(c.number)).font(numberFont).monospacedDigit().textSelection(.enabled)
            if !c.callerName.isEmpty { Tag(text: c.callerName.capitalized, color: flagged ? .red : .secondary) }
        }
    }

    @ViewBuilder private func said(_ c: Call) -> some View {
        if c.isText, !c.body.isEmpty {
            Text("“\(c.body.replacingOccurrences(of: "\n", with: " "))”").font(.callout).lineLimit(2).textSelection(.enabled)
        }
    }

    private func onFile(_ c: Call) -> some View {
        Group {
            if let r = c.reports {
                Tag(text: r == 1 ? "1 FCC complaint" : "\(r) FCC complaints", color: r >= settings.likelyReports ? .red : .secondary)
            }
        }
    }

    private func recentRow(_ c: Call) -> some View {
        let (symbol, color, label): (String, Color, String) = switch c.status {
        case "filed": ("checkmark.circle.fill", .green, "Filed")
        case "asked": ("clock.fill", .orange, "Needs your answer")
        case "scheduled": ("timer.circle.fill", .orange, "Files at \(clock(Double(c.ref ?? "") ?? 0))")
        case "ignored": ("hand.raised.circle.fill", .gray, "Ignored")
        case "repeat": ("arrow.triangle.2.circlepath.circle.fill", .gray, "Same caller, same day")
        case "link": ("xmark.octagon.fill", .red, "Not filed")
        case "unsent": ("exclamationmark.circle.fill", .orange, "Message not sent")
        default: ("circle", .gray, c.status)
        }
        return HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                title(c, flagged: engine.likely(c))
                Text("\(whenText(c.date)) · \(heard(c).prefix(1).uppercased() + heard(c).dropFirst())").font(.callout).foregroundStyle(.secondary)
                said(c)
            }
            Spacer(minLength: 8)
            onFile(c)
            VStack(alignment: .trailing, spacing: 1) {
                Text(label).font(.callout.weight(.medium)).foregroundStyle(color == .gray ? .secondary : color)
                if c.status == "filed", let ref = c.ref, ref != "accepted" {
                    Text("Request \(ref)").font(.caption).foregroundStyle(.secondary).monospacedDigit().textSelection(.enabled)
                }
            }.frame(width: 150, alignment: .trailing)
        }.padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func waitingRow(_ c: Call) -> some View {
        let busy = engine.filing.contains(c.uid), likely = engine.likely(c)
        let note = c.status == "link" ? "The last try failed" : c.status == "scheduled" ? "Files by itself at \(clock(Double(c.ref ?? "") ?? 0))" : (heard(c).prefix(1).uppercased() + heard(c).dropFirst())
        return HStack(spacing: 12) {
            IconTile(symbol: likely ? "exclamationmark.triangle.fill" : "questionmark", color: likely ? .orange : .blue, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                title(c, flagged: likely)
                Text("\(whenText(c.date)) · \(note)").font(.callout).foregroundStyle(.secondary)
                said(c)
            }
            Spacer(minLength: 8)
            onFile(c)
            if busy { ProgressView().controlSize(.small) }
            Button("Ignore", role: .destructive) { askIgnore = c }.tint(.red).disabled(busy)
            Button(busy ? "Filing" : c.status == "scheduled" ? "File Now" : "File Complaint") { Task { await engine.answer("1", uid: c.uid) } }
                .buttonStyle(.borderedProminent).disabled(busy || !settings.ready)
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }
}

func openFullDiskAccess() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
}

// MARK: Ignored

struct IgnoredView: View {
    @EnvironmentObject var engine: Engine
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if engine.ignored.isEmpty {
                    Card { HStack(spacing: 14) {
                        IconTile(symbol: "hand.raised.fill", color: .red, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("No ignored numbers").font(.headline)
                            Text("When you ignore a caller, Spamurai never asks about that number again. People in your contacts are always left alone.")
                                .foregroundStyle(.secondary)
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    Card { ForEach(Array(engine.ignored.enumerated()), id: \.element) { i, n in
                        if i > 0 { Divider().padding(.leading, 50) }
                        HStack(spacing: 12) {
                            Image(systemName: "hand.raised.circle.fill").font(.title2).foregroundStyle(.red)
                            Text(dashed(n)).font(numberFont).monospacedDigit().textSelection(.enabled)
                            Spacer()
                            Button("Stop Ignoring") { engine.stopIgnoring(n) }
                        }.padding(.horizontal, 14).padding(.vertical, 8)
                    } }
                }
            }
            .padding(24).frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Ignored")
    }
}

// MARK: Setup

struct SetupView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var settings: Settings
    @State private var testResult = ""
    @State private var hasThread = false
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    static let states = "Alabama,Alaska,American Samoa,Arizona,Arkansas,California,Colorado,Connecticut,Delaware,District of Columbia,Florida,Georgia,Guam,Hawaii,Idaho,Illinois,Indiana,Iowa,Kansas,Kentucky,Louisiana,Maine,Maryland,Massachusetts,Michigan,Minnesota,Mississippi,Missouri,Montana,Nebraska,Nevada,New Hampshire,New Jersey,New Mexico,New York,North Carolina,North Dakota,Northern Mariana Islands,Ohio,Oklahoma,Oregon,Pennsylvania,Puerto Rico,Rhode Island,South Carolina,South Dakota,Tennessee,Texas,U.S. Virgin Islands,Utah,Vermont,Virginia,Washington,West Virginia,Wisconsin,Wyoming".components(separatedBy: ",")

    private func picker(_ title: String, _ binding: Binding<String>, _ options: [(String, String)], choose: Bool = true) -> some View {
        Picker(title, selection: binding) {
            if choose && binding.wrappedValue.isEmpty { Text("Choose").tag("") }
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
    }

    private func head(_ title: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 8) { IconTile(symbol: symbol, color: color, size: 22); Text(title).font(.headline) }.padding(.bottom, 2)
    }

    private func step(_ done: Bool, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if !done { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }

    private var detailsDone: Bool { Settings.requiredMe.allSatisfy { !(settings.me[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty } }
    private var answersDone: Bool { Settings.answerKeys.allSatisfy { !(settings.answers[$0] ?? "").isEmpty } && settings.agreed }
    private var askingDone: Bool { settings.notifyKind != "imessage" || hasThread }

    var body: some View {
        Form {
            Section {
                step(detailsDone, "Your details", "Fill in your name, address, email and cell number below.")
                step(answersDone, "Your answers about the calls", "Choose the four answers and switch on the agreement.")
                step(askingDone, "How Spamurai asks you", "Send yourself one iMessage from this Mac, or choose another way under Asking you.")
                step(engine.access == "ok", "Access to your calls", "Switch Spamurai on in Full Disk Access, then quit and reopen it.")
            } header: {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(settings.ready && engine.access == "ok" && askingDone ? "Spamurai is ready" : "Set up Spamurai").font(.title2.weight(.semibold))
                        Text("Four things, then it watches your calls by itself.").foregroundStyle(.secondary)
                    }
                }.padding(.bottom, 6).textCase(nil)
            }

            Section {
                TextField("First name", text: settings.bindMe("first_name")).textContentType(.givenName)
                TextField("Last name", text: settings.bindMe("last_name")).textContentType(.familyName)
                TextField("Email", text: settings.bindMe("email"), prompt: Text("For the FCC's confirmations")).textContentType(.emailAddress)
                TextField("Cell number", text: settings.bindMe("phone"), prompt: Text("The phone that gets the calls"))
                TextField("Street address", text: settings.bindMe("address1"), prompt: Text("Or PO Box"))
                TextField("Apartment, suite", text: settings.bindMe("address2"), prompt: Text("Optional"))
                TextField("City", text: settings.bindMe("city"))
                picker("State", settings.bindMe("state"), SetupView.states.map { ($0, $0) })
                TextField("Zip code", text: settings.bindMe("zip"))
            } header: { head("Your details", "person.fill", .blue) } footer: {
                Text("The FCC requires these on every complaint. They are kept on this Mac and sent only to the FCC.")
            }

            Section {
                picker("Type of call", settings.bindAnswer("call_type"), [("prerecorded", "Prerecorded voice"), ("live", "Live voice")])
                picker("Did the call advertise property, goods or services?", settings.bindAnswer("advertised"), [("no", "No"), ("yes", "Yes")])
                picker("Was the caller's business name given?", settings.bindAnswer("name_given"), [("no", "No"), ("uncertain", "Uncertain")])
                picker("Did the caller claim to be an organization it was not?", settings.bindAnswer("imposter"), [("no", "No"), ("yes", "Yes"), ("uncertain", "Uncertain")])
                picker("Have you given the caller permission to call?", settings.bindMe("gave_permission"), [("no", "No"), ("uncertain", "Uncertain")], choose: false)
                picker("Is your number on the Do Not Call list?", settings.bindMe("on_do_not_call_list"), [("yes", "Yes"), ("no", "No"), ("uncertain", "Uncertain")], choose: false)
                picker("The phone is", settings.bindMe("phone_type"), [("personal", "Personal"), ("business", "Business")], choose: false)
                Label {
                    Text("Every complaint carries the FCC's statement: “I declare under penalty of perjury that (1) I am over 18 years old, (2) I am authorized to make decisions regarding the telephone number listed below, and (3) the information I have provided today on this Federal Communications Commission electronic form is, to the best of my knowledge, true and correct.”")
                        .font(.callout).foregroundStyle(.secondary)
                } icon: { Image(systemName: "signature").foregroundStyle(.orange) }
                Toggle("Spamurai may file complaints in my name with this statement and these answers",
                       isOn: Binding(get: { settings.agreed }, set: { settings.agreed = $0; settings.save() }))
            } header: { head("Your answers about the calls", "text.bubble.fill", .purple) } footer: {
                Text("The complaint form asks these about each call. Spamurai files every complaint with the answers you choose here, so pick what is true for the calls you report.")
            }

            Section {
                Toggle("Watch text messages too", isOn: Binding(get: { settings.watchTexts }, set: { settings.watchTexts = $0; settings.save() }))
                Toggle("File likely robocalls and spam texts without asking", isOn: Binding(get: { settings.autoFile }, set: { settings.autoFile = $0; settings.save() }))
                if settings.autoFile {
                    Picker("Wait before filing", selection: Binding(get: { settings.graceMinutes }, set: { settings.graceMinutes = $0; settings.save() })) {
                        Text("Don't wait").tag(0)
                        Text("10 minutes").tag(10)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                        Text("4 hours").tag(240)
                    }
                }
            } header: { head("Filing", "checkmark.seal.fill", .green) } footer: {
                Text("Likely means \(settings.likelyReports) or more FCC complaints on file for the number, or a spam label from your carrier. While Spamurai waits, you are told and can stop the filing by ignoring the number. A call you talked on is always asked about. Texts are filed with the same answers, as a text message, with what the message said. Sign-in codes and anyone you have written to are left alone.")
            }

            Section {
                Picker("Ask me with", selection: Binding(get: { settings.notifyKind }, set: { settings.notifyKind = $0; settings.save() })) {
                    Text("An iMessage to myself").tag("imessage")
                    Text("A notification on this Mac").tag("mac")
                    Text("Nothing, I'll check Spamurai").tag("none")
                }
                if settings.notifyKind == "imessage" {
                    // Shows the cell number until the owner types another address; the placeholder never contains their details.
                    TextField("My iMessage address",
                              text: Binding(get: { settings.imessageTo.isEmpty ? dashed(settings.me["phone"]) : settings.imessageTo },
                                            set: { settings.imessageTo = $0; settings.save(); hasThread = engine.notifier.selfThread() != nil }),
                              prompt: Text("Enter your number or Apple Account email"))
                    if !hasThread {
                        LabeledContent {
                            Button("Open Messages") { engine.notifier.openSelfThread() }
                        } label: {
                            Label("Send yourself one message first, any text. Spamurai writes to that conversation.", systemImage: "arrow.turn.down.right").foregroundStyle(.orange)
                        }
                    }
                }
                if settings.notifyKind != "none" {
                    LabeledContent(engine.testOutcome.isEmpty ? testResult : engine.testOutcome) {
                        Button("Send a Test Question") {
                            engine.testOutcome = ""
                            Task { testResult = await engine.sendTestQuestion() }
                        }.disabled(settings.notifyKind == "imessage" && !hasThread)
                    }
                }
            } header: { head("Asking you", "message.fill", .green) } footer: {
                Text(settings.notifyKind == "imessage"
                     ? "The question reaches your iPhone as a message from yourself. Reply 1 to file or 2 to ignore. Leave the address empty to use your cell number. The test asks about a made-up call and files nothing."
                     : settings.notifyKind == "mac" ? "The notification has File and Ignore buttons. The test asks about a made-up call and files nothing."
                     : "Spamurai stays quiet. Callers it is unsure about wait on the Calls page, where you file or ignore them. The menu bar icon shows how many are waiting.")
            }

            Section {
                LabeledContent {
                    if engine.access != "ok" { Button("Open Full Disk Access") { openFullDiskAccess() } }
                } label: {
                    Label(engine.access == "ok" ? "Spamurai can read your calls" : "No access to your calls yet",
                          systemImage: engine.access == "ok" ? "checkmark.circle.fill" : "lock.circle.fill")
                        .foregroundStyle(engine.access == "ok" ? Color.green : .red)
                }
                Toggle("Open Spamurai when I log in", isOn: Binding(get: { atLogin }, set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                    atLogin = SMAppService.mainApp.status == .enabled
                }))
            } header: { head("This Mac", "macbook", .gray) } footer: {
                Text(engine.access == "ok" ? "Calls sync from your iPhone when it uses the same Apple Account as this Mac. Spamurai keeps watching from the menu bar after you close this window."
                     : "macOS only lets apps with Full Disk Access read the calls your iPhone syncs to this Mac, and your replies in Messages. Switch Spamurai on in the list (press + and choose it if it is not there), then quit and reopen Spamurai.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
        .onAppear { hasThread = engine.notifier.selfThread() != nil }
        .task {
            while !Task.isCancelled {   // notices the first message to yourself without a restart
                hasThread = engine.notifier.selfThread() != nil
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }
}
