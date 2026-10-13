import AppKit
import SwiftUI

/// The Raphael Control Center window. Polling (nodes, Hermes stats) only runs
/// while it is on screen, so a closed window costs nothing.
@MainActor
final class ControlCenterWindow: NSObject, NSWindowDelegate {
    static let shared = ControlCenterWindow()
    private var window: NSWindow?
    private var statsTimer: Timer?

    func show(section: CCSection? = nil) {
        if let section { UserDefaults.standard.set(section.rawValue, forKey: "raphaelCCSection") }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Raphael"
            Self.applyAppearance(to: w)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ControlCenterView())
            w.setFrameAutosaveName("RaphaelControlCenter")
            if !w.setFrameUsingName("RaphaelControlCenter") { w.center() }
            w.delegate = self
            window = w
        }
        NodeStore.shared.startPolling()
        Self.refreshSlow()
        Self.loadEndpoint()
        OmniRouteStore.shared.followDevice()
        RaphaelAgent.shared.reloadList()
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in ControlCenterWindow.refreshSlow() }
        }
        // Dock icon + ⌘-Tab while the window is open; back to menu-bar-only when closed.
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Writes the window's current rendering to Application Support/Raphael/snapshots/<name>.png
    /// (raphael://snapshot?name=…): lets tooling check the UI without screen-recording rights.
    func snapshot(name: String) {
        guard let view = window?.contentView else { NSLog("Raphael snapshot: no window"); return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSLog("Raphael snapshot: no rep"); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let dir = NodeStore.supportDir.appendingPathComponent("snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// "system" (follow macOS), "light" or "dark" — chosen in the sidebar.
    static func applyAppearance(to w: NSWindow? = nil) {
        let mode = UserDefaults.standard.string(forKey: "raphaelAppearance") ?? "system"
        let target = w ?? shared.window
        target?.appearance = mode == "light" ? NSAppearance(named: .aqua) : mode == "dark" ? NSAppearance(named: .darkAqua) : nil
    }

    /// Switch the device the window looks at and reload everything that is per-device.
    static func switchDevice(to id: String) {
        let ctx = DeviceContext.shared
        guard ctx.currentId != id else { return }
        ctx.currentId = id                     // posts .raphaelDeviceChanged (chat + knowledge reload)
        HermesStats.shared.snapshot = HermesSnapshot()
        HermesStats.shared.refresh()
        TailscaleStore.shared.peers = []
        TailscaleStore.shared.refresh()
        OmniRouteStore.shared.followDevice()
        loadEndpoint()
    }

    static func loadEndpoint() {
        let node = DeviceContext.shared.current
        Task {
            let ep = await DeviceContext.endpoint(node)
            if DeviceContext.shared.currentId == node.id { DeviceContext.shared.endpointCache = ep }
        }
    }

    /// Everything that is not a node probe: Hermes stats, OmniRoute, Tailscale, websites.
    static func refreshSlow() {
        HermesStats.shared.refresh()
        OmniRouteStore.shared.refreshAll()
        TailscaleStore.shared.refresh()
        SiteStore.shared.checkAll()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { [weak self] in
            self?.window?.contentView = nil
            self?.window = nil
        }
        NodeStore.shared.stopPolling()
        statsTimer?.invalidate()
        statsTimer = nil
    }
}
