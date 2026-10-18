import AppKit
import SwiftUI
import Combine

// RemotePanel, PanelArrow, PanelShell and AppDelegate are ported from
// LGwebOS-menubar (MIT); see THIRD_PARTY_NOTICES.md.
final class RemotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct PanelArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - 11, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.midX - 3, y: rect.minY + 2), control: CGPoint(x: rect.midX - 6, y: rect.maxY - 6))
        path.addQuadCurve(to: CGPoint(x: rect.midX + 3, y: rect.minY + 2), control: CGPoint(x: rect.midX, y: rect.minY - 2))
        path.addQuadCurve(to: CGPoint(x: rect.midX + 11, y: rect.maxY), control: CGPoint(x: rect.midX + 6, y: rect.maxY - 6))
        path.closeSubpath()
        return path
    }
}

private struct PanelShell: View {
    @ObservedObject var store: ACStore
    let height: CGFloat
    let arrowX: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            PanelArrow().fill(Theme.arrowFill)
                .frame(width: Theme.arrowWidth, height: Theme.arrowHeight).frame(width: Theme.panelWidth, alignment: .leading).offset(x: arrowX - Theme.arrowWidth / 2)
            ACView(store: store).frame(width: Theme.panelWidth, height: height - Theme.arrowHeight)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Color.white.opacity(Theme.borderOpacity), lineWidth: Theme.borderWidth))
        }.frame(width: Theme.panelWidth, height: height).preferredColorScheme(.dark)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ACStore()
    var statusItem: NSStatusItem!
    let panel = RemotePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var host: NSHostingController<PanelShell>?
    var clickMonitor: Any?
    var keyMonitor: Any?
    private var sizeSubscription: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "air.conditioner.horizontal", accessibilityDescription: "DaikinAC-menubar")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.target = self; statusItem.button?.action = #selector(toggle)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        sizeSubscription = store.$preferredPanelHeight.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { if self?.panel.isVisible == true { self?.show() } }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.panel.orderOut(nil) }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.panel.isVisible == true { self?.panel.orderOut(nil); return nil }
            return event
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !CommandLine.arguments.contains("--background") { self.show() }
        }
    }
    @objc func toggle() { if panel.isVisible { panel.orderOut(nil) } else { show() } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func show() {
        guard let button = statusItem.button, let anchorWindow = button.window else { return }
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = anchorWindow.screen ?? NSScreen.main!
        let visible = screen.visibleFrame
        let top = min(anchor.minY - 3, visible.maxY - 3)
        let height = min(store.preferredPanelHeight, max(Theme.minimumPanelHeight, top - visible.minY - 12))
        let half = Theme.panelWidth / 2
        let x = min(max(anchor.midX - half, visible.minX + 8), visible.maxX - Theme.panelWidth - 8)
        let root = PanelShell(store: store, height: height, arrowX: min(Theme.panelWidth - 18, max(18, anchor.midX - x)))
        if let host { host.rootView = root }
        else { let controller = NSHostingController(rootView: root); host = controller; panel.contentViewController = controller }
        // Use screen coordinates explicitly so AppKit cannot flip the panel above the menu bar.
        panel.setFrame(NSRect(x: x, y: top - height, width: Theme.panelWidth, height: height), display: true)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--help") {
    print("""
    DaikinAC-menubar — a macOS menu bar controller for Daikin Smart AC (Brazil)

    Run the app normally and sign in with your own Daikin account in Settings.
    --background   Start without showing the panel.
    --tab <name>   Open the panel on Control, Energy, Health, Schedules or Settings.
    --self-check   Run offline checks. No network, Keychain or AC access.
    """)
} else if CommandLine.arguments.contains("--self-check") {
    Task { do { try await FeatureChecks.run(); exit(0) } catch { print("FAIL: \(error.localizedDescription)"); exit(1) } }
    RunLoop.main.run()
} else {
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
