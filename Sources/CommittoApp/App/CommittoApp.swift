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
    func applicationWillTerminate(_ notification: Notification) { statusController?.tearDown(); ProcessSupervisor.shared.terminateAll() }
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

    /// The approved Committo glyph (docs/assets/menubar.svg, 24-unit grid, y down) drawn as a template image.
    /// `badge` adds a dot at the top left to show live agent or dirty-repo activity.
    static func icon(badge: Bool) -> NSImage {
        let side: CGFloat = 18
        let img = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            let u = rect.width / 24
            func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * u, y: y * u) }
            func disc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath {
                NSBezierPath(ovalIn: NSRect(x: (x - r) * u, y: (y - r) * u, width: 2 * r * u, height: 2 * r * u))
            }
            NSColor.black.set()
            let lane = NSBezierPath(); lane.move(to: P(15.5, 21)); lane.line(to: P(15.5, 6.5))
            let branch = NSBezierPath(); branch.move(to: P(8.5, 20.5))
            branch.curve(to: P(15.5, 12.5), controlPoint1: P(8.5, 15.5), controlPoint2: P(15.5, 17))
            let head = disc(15.5, 4.2, 2.5)
            for path in [lane, branch, head] { path.lineWidth = 2.3 * u; path.lineCapStyle = .round; path.stroke() }
            disc(15.5, 12.8, 2.1).fill()
            disc(8.5, 20.2, 1.9).fill()
            if badge { disc(4.5, 4.5, 3).fill() }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Committo"
        return img
    }

    /// Stops the badge timer and removes the status item; called on quit.
    func tearDown() {
        badgeTimer?.invalidate(); badgeTimer = nil
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(item)
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
