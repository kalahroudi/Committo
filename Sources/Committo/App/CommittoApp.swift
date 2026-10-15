import SwiftUI
import AppKit
import CommittoCore

@main
struct CommittoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { SettingsView().environment(AppModel.shared).frame(width: 640, height: 480) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusController: StatusItemController?
    var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        windowController = MainWindowController(model: model)
        statusController = StatusItemController(model: model) { [weak self] in self?.windowController?.show() }
        model.openMainWindow = { [weak self] in self?.windowController?.show() }
        model.closePopover = { [weak self] in self?.statusController?.close() }
        Task { await model.bootstrap() }
        if !UserDefaults.standard.bool(forKey: "menuBarOnly") { windowController?.show() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { windowController?.show(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor
final class MainWindowController {
    private var window: NSWindow?
    private let model: AppModel
    init(model: AppModel) { self.model = model }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: MainWindow().environment(model))
            let w = NSWindow(contentViewController: host)
            w.title = "Committo"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.setContentSize(NSSize(width: 1220, height: 780))
            w.minSize = NSSize(width: 900, height: 600)
            w.setFrameAutosaveName("CommittoMain")
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Menu-bar icon + NSPopover. NSPopover (rather than MenuBarExtra's window) gives the native arrow
/// that visually links the popover to the status icon.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel
    private var monitor: Any?
    private var badgeTimer: Timer?

    init(model: AppModel, openMain: @escaping () -> Void) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 400, height: 560)
        popover.contentViewController = NSHostingController(rootView: PopoverView().environment(model))
        if let b = item.button {
            b.image = Self.icon(badge: false)
            b.target = self; b.action = #selector(toggle(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in self?.updateBadge() } }
    }

    static func icon(badge: Bool) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let img = NSImage(systemSymbolName: badge ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted", accessibilityDescription: "Committo")?.withSymbolConfiguration(cfg) ?? NSImage()
        img.isTemplate = true
        return img
    }

    func updateBadge() {
        let live = model.recents.contains { $0.dirty > 0 } || model.lens.contains { $0.isLive }
        item.button?.image = Self.icon(badge: live)
        let behind = model.recents.reduce(0) { $0 + $1.behind }
        item.button?.title = behind > 0 ? " \(behind)" : ""
    }

    @objc func toggle(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        if popover.isShown { close() } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await model.refreshRecents() }
        }
    }
    func close() { popover.performClose(nil) }

    private func showMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "Open Committo", action: #selector(openMain), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m; item.button?.performClick(nil); item.menu = nil
    }
    @objc func openMain() { model.openMainWindow?() }
}
