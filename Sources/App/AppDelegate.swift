import AppKit
import ServiceManagement

/// Menu bar app: the status item opens the Control Center; raphael:// URLs drive it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        SettingsMigration.run()
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        setUpStatusItem()
        // Metrics are sampled from launch so the Monitor has history when opened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { _ = MonitorStore.shared; _ = WorkspaceStore.shared; _ = DevStore.shared }
        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            ControlCenterWindow.shared.show()
        }
    }

    /// A menu-bar app has no menu bar, but text fields only get ⌘C/⌘V/⌘X/⌘A/⌘Z through the
    /// key equivalents of a main menu — so install a minimal (invisible) one.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Tutup jendela", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Keluar Raphael", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ControlCenterWindow.shared.show()
        return true
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "triangle.fill", accessibilityDescription: "Raphael")
        button.image?.size = NSSize(width: 18, height: 18)
        button.image?.isTemplate = true
        button.image?.accessibilityDescription = "Raphael Control Center"
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    /// Rebuilt each time it opens, so dashboards and the login item reflect the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, "Buka Control Center", #selector(openControlCenter), key: "r", mods: [.command, .shift])
        add(menu, "Monitor", #selector(openMonitor))
        add(menu, "Chat Raphael", #selector(openChat))
        add(menu, "File", #selector(openFiles))
        menu.addItem(.separator())

        let links = NSMenuItem(title: "Buka dashboard", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if !MonitorStore.webURL.isEmpty {
            let item = add(sub, "Raphael Web", #selector(openLink(_:)))
            item.representedObject = MonitorStore.webURL
            sub.addItem(.separator())
        }
        for inst in OmniRouteStore.shared.instances {
            let item = add(sub, "OmniRoute · \(inst.name)", #selector(openLink(_:)))
            item.representedObject = inst.dashboardURL
        }
        for site in SiteStore.shared.sites {
            let item = add(sub, site.name, #selector(openLink(_:)))
            item.representedObject = site.url
        }
        links.submenu = sub
        menu.addItem(links)

        let alerts = MonitorStore.shared.alerts(for: NodeStore.shared.nodes).filter { $0.level == .bad }
        if !alerts.isEmpty {
            let a = NSMenuItem(title: "⚠︎ \(alerts.count) sinyal kritis", action: #selector(openMonitor), keyEquivalent: "")
            a.target = self
            menu.addItem(a)
        }
        menu.addItem(.separator())
        let login = add(menu, "Buka saat login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        add(menu, "Keluar", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        return item
    }

    @objc private func openControlCenter() { ControlCenterWindow.shared.show() }
    @objc private func openMonitor() { ControlCenterWindow.shared.show(section: .monitor) }
    @objc private func openChat() { ControlCenterWindow.shared.show(section: .chat) }
    @objc private func openFiles() { ControlCenterWindow.shared.show(section: .files) }
    @objc private func openLink(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: raphael:// URLs

    /// raphael://<section>, ?q= (chat), ?session=&device=, raphael://device?id=, raphael://snapshot?name=,
    /// raphael://knowledge?add=/path&collection=Name · ?repo=https://…
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "raphael" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func q(_ name: String) -> String? { items.first { $0.name == name }?.value }
            switch url.host {
            case "device":
                if let id = q("id") { ControlCenterWindow.shared.show(); ControlCenterWindow.switchDevice(to: id) }
                continue
            case "snapshot":
                ControlCenterWindow.shared.snapshot(name: q("name") ?? "window")
                continue
            default: break
            }
            let section = CCSection(urlHost: url.host ?? "")
            ControlCenterWindow.shared.show(section: section)
            if section == .chat, let sid = q("session") { RaphaelAgent.shared.select(sid, device: q("device")) }
            if section == .chat, let text = q("q") { RaphaelAgent.shared.newChat(); RaphaelAgent.shared.send(text) }
            if section == .knowledge {
                let adds = items.filter { $0.name == "add" }.compactMap(\.value).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                if !adds.isEmpty {
                    UserDefaults.standard.set("Knowledge Graph", forKey: "raphaelKnowledgeTab")
                    KnowledgeStore.shared.ingest(adds, collection: q("collection") ?? KnowledgeStore.defaultCollection)
                }
                if let repo = q("repo") { KnowledgeStore.shared.cloneAndBuild(repo) }
            }
        }
    }
}
