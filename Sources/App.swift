import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var engine: Engine!
    var window: NSWindow?
    var statusItem: NSStatusItem!
    var timer: Timer?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let env = ProcessInfo.processInfo.environment
        let demo = env["SPAMURAI_DEMO"]
        let home = demo ?? NSHomeDirectory() + "/Library/Application Support/Spamurai"
        if demo == nil { AppDelegate.adoptOldSettings(into: home) }
        engine = Engine(home: home, demo: demo != nil)
        buildMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "phone.arrow.down.left.fill", accessibilityDescription: "Spamurai")
        refreshStatusMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshStatusMenu() } }
        NotificationCenter.default.addObserver(forName: .init("SpamuraiOpenWindow"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showWindow() }
        }
        if env["SPAMURAI_FILL_TEST"] != nil { fillTest(); return }
        if env["SPAMURAI_FILE_PENDING"] != nil { filePending(); return }
        if let days = env["SPAMURAI_TEXT_PREVIEW"] {
            print((try? engine.previewTexts(days: Double(days) ?? 14)) ?? "no access to Messages")
            exit(0)
        }
        if env["SPAMURAI_TEST_MESSAGE"] != nil {
            Task { @MainActor in
                print("test question:", await engine.sendTestQuestion())
                exit(0)
            }
            return
        }
        if let look = env["SPAMURAI_APPEARANCE"] { NSApp.appearance = NSAppearance(named: look == "light" ? .aqua : .darkAqua) }
        engine.start()
        // Started at login it stays in the menu bar; opened by hand it shows its window.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == kAEOpenApplication && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if atLogin || CommandLine.arguments.contains("--background") { NSApp.setActivationPolicy(.accessory) } else { showWindow() }
    }

    /// The app was called Callwatch before 2.0: bring its settings and history along once.
    static func adoptOldSettings(into home: String) {
        let fm = FileManager.default, old = NSHomeDirectory() + "/Library/Application Support/Callwatch"
        guard !fm.fileExists(atPath: home + "/config.json"), fm.fileExists(atPath: old + "/config.json") else { return }
        try? fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        for file in ["config.json", "state.db"] { try? fm.copyItem(atPath: "\(old)/\(file)", toPath: "\(home)/\(file)") }
    }

    /// Fills the real FCC form for a made-up call without sending it, and prints what happened.
    private func fillTest() {
        Task { @MainActor in
            let call = Call(uid: "test", number: "8445550123", ts: Date().timeIntervalSince1970 - 3600, callerName: "")
            do { print("fill test:", try await engine.filer.file(call, engine.settings, submit: false)) }
            catch { print("fill test failed:", (error as? FilingError)?.message ?? "\(error)") }
            exit(0)
        }
    }

    /// Files the likely robocalls that are still open (asked, or a failed earlier try), prints each outcome and quits.
    private func filePending() {
        Task { @MainActor in
            let open = engine.store.calls(where: "status in ('asked','link')").filter { engine.likely($0) }
            print("open likely robocalls:", open.count)
            for call in open {
                await engine.file(call)
                let after = engine.store.calls(where: "uid=?", [call.uid]).first
                print(dashed(call.number), "->", after?.status ?? "?", after?.ref ?? "", engine.lastProblem)
            }
            exit(0)
        }
    }

    @objc func showWindow() {
        if window == nil {
            let page = Page(rawValue: ProcessInfo.processInfo.environment["SPAMURAI_PAGE"] ?? "") ?? .calls
            let root = RootView(page: page).environmentObject(engine!).environmentObject(engine.settings)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Spamurai"
            w.toolbarStyle = .unified
            w.toolbar = NSToolbar(identifier: "main")
            w.contentViewController = NSHostingController(rootView: root)
            w.setContentSize(NSSize(width: 1040, height: 720))
            w.minSize = NSSize(width: 860, height: 520)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("SpamuraiMain")
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }   // keep watching from the menu bar
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return false }

    private func refreshStatusMenu() {
        let menu = NSMenu()
        let state = !engine.running ? "Not running" : engine.access == "denied" ? "Can't read the call log" : !engine.settings.ready ? "Setup not finished" : "Watching for calls"
        menu.addItem(withTitle: state, action: nil, keyEquivalent: "")
        if engine.stats.waiting > 0 { menu.addItem(withTitle: "\(engine.stats.waiting) waiting for you", action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Spamurai", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Spamurai", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.title = engine.stats.waiting > 0 ? " \(engine.stats.waiting)" : ""
    }

    private func buildMenu() {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "About Spamurai", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Spamurai", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Spamurai", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        for m in [app, edit, win] { let item = NSMenuItem(); item.submenu = m; main.addItem(item) }
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }
}
