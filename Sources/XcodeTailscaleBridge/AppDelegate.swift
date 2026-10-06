import AppKit
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let enabledKey = "bridgeEnabled"

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let bridge = Bridge()
    private var status = Bridge.Status()
    private var capturing = false
    private var terminationSource: DispatchSourceSignal?

    private var bridgeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        // Quit normally on SIGTERM (kill, logout) so applicationWillTerminate cleans up.
        signal(SIGTERM, SIG_IGN)
        terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSource?.setEventHandler { NSApp.terminate(nil) }
        terminationSource?.resume()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        bridge.onChange = { [weak self] status in
            self?.status = status
            self?.refresh()
        }
        status.devices = DeviceStore.load().map {
            Bridge.DeviceStatus(device: $0, tailscaleIP: nil, controlConnections: 0, tunnelConnections: 0)
        }
        refresh()
        if bridgeEnabled { bridge.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge.shutdown()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    // MARK: Status item

    private func refresh() {
        let anyTunnel = status.devices.contains { $0.tunnelConnections > 0 }
        let symbol: String
        switch status.state {
        case .stopped: symbol = "iphone.slash"
        case .failed: symbol = "exclamationmark.triangle"
        case .running: symbol = anyTunnel ? "iphone.radiowaves.left.and.right" : "iphone"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Xcode Tailscale Bridge")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Xcode Tailscale Bridge — \(stateText)"
        rebuildMenu()
    }

    private var stateText: String {
        switch status.state {
        case .stopped: return "Off"
        case .failed(let message): return message
        case .running:
            if let interface = status.interface, let ip = status.localIP { return "Relaying via \(interface) (\(ip))" }
            return "Running"
        }
    }

    // MARK: Menu

    private func rebuildMenu() {
        menu.removeAllItems()

        let title = NSMenuItem(title: "Xcode Tailscale Bridge", action: nil, keyEquivalent: "")
        title.attributedTitle = NSAttributedString(string: "Xcode Tailscale Bridge",
                                                   attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(disabled(stateText))
        if let warning = status.warning { menu.addItem(disabled("⚠︎ \(warning)")) }
        menu.addItem(.separator())

        if status.devices.isEmpty {
            menu.addItem(disabled("No devices captured yet"))
        } else {
            for deviceStatus in status.devices { menu.addItem(deviceItem(deviceStatus)) }
        }
        menu.addItem(.separator())

        menu.addItem(item(bridgeEnabled ? "Turn Bridge Off" : "Turn Bridge On", #selector(toggleBridge)))
        let capture = item(capturing ? "Capturing…" : "Capture Devices on This Network…", #selector(captureDevices))
        capture.isEnabled = !capturing
        menu.addItem(capture)
        menu.addItem(.separator())

        let advanced = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(item("Import devices.json…", #selector(importDevices)))
        submenu.addItem(.separator())
        submenu.addItem(item("Restart Pairing Service", #selector(restartPairingService)))
        submenu.addItem(item("Show Log", #selector(showLog)))
        submenu.addItem(item("Show Devices File", #selector(showDevicesFile)))
        submenu.addItem(.separator())
        submenu.addItem(item("About Xcode Tailscale Bridge", #selector(showAbout)))
        advanced.submenu = submenu
        menu.addItem(advanced)

        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = Bundle.main.bundleURL.pathExtension == "app"
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit Xcode Tailscale Bridge", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    private func deviceItem(_ deviceStatus: Bridge.DeviceStatus) -> NSMenuItem {
        let device = deviceStatus.device
        let (label, color): (String, NSColor) = {
            guard status.state == .running else { return ("bridge off", .tertiaryLabelColor) }
            if let problem = deviceStatus.problem { return (problem, .systemRed) }
            if deviceStatus.tunnelConnections > 0 { return ("connected", .systemGreen) }
            if deviceStatus.controlConnections > 0 { return ("available", .systemBlue) }
            if deviceStatus.tailscaleIP != nil { return ("waiting for Xcode", .systemYellow) }
            return ("offline in Tailscale", .tertiaryLabelColor)
        }()
        let title = "\(device.name.displaySafe) — \(label)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = statusTitle(title, color: color)

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(disabled("Tailscale: \(device.tailscale)\(deviceStatus.tailscaleIP.map { " (\($0))" } ?? "")"))
        submenu.addItem(disabled("UDID: \(device.udid)"))
        submenu.addItem(disabled("Captured: \(device.captured)"))
        if deviceStatus.problem != nil {
            submenu.addItem(disabled("A different Tailscale node is using this name."))
            submenu.addItem(disabled("If that's this device, capture it again to trust it."))
        }
        submenu.addItem(.separator())
        let copy = self.item("Copy UDID", #selector(copyUDID(_:)))
        copy.representedObject = device.udid
        submenu.addItem(copy)
        let remove = self.item("Remove Device…", #selector(removeDevice(_:)))
        remove.representedObject = device
        submenu.addItem(remove)
        item.submenu = submenu
        return item
    }

    /// A device row's title, prefixed with a dot in its status colour. The dot is text rather
    /// than the item's image because status menus don't reliably show item images.
    private func statusTitle(_ title: String, color: NSColor) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let text = NSMutableAttributedString(string: "●\u{2002}", attributes: [.foregroundColor: color, .font: font])
        text.append(NSAttributedString(string: title, attributes: [.font: font]))
        return text
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Actions

    @objc private func toggleBridge() {
        bridgeEnabled.toggle()
        if bridgeEnabled { bridge.start() } else { bridge.stop() }
        rebuildMenu()
    }

    @objc private func captureDevices() {
        capturing = true
        rebuildMenu()
        DispatchQueue.global().async {
            let result = Result { try Capture.run() }
            DispatchQueue.main.async {
                self.capturing = false
                self.showCaptureResult(result)
                self.bridge.restart()
                self.rebuildMenu()
            }
        }
    }

    private func showCaptureResult(_ result: Result<Capture.Report, Error>) {
        let alert = NSAlert()
        switch result {
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = "Capture failed"
            alert.informativeText = error.localizedDescription
        case .success(let report):
            alert.messageText = report.captured.isEmpty ? "No paired devices found" : "Captured \(report.captured.count) device(s)"
            var lines = report.captured.map { "✓ \($0.name.displaySafe) (Tailscale name: \($0.tailscale))" }
            lines += report.missing.map { "✗ \($0.displaySafe): not seen. Is it awake and on this network?" }
            lines += report.conflicts.map { "⚠︎ \($0.displaySafe): skipped, because more than one device on this network claims to be it" }
            lines += report.notPaired.map { "– \($0.displaySafe): not paired with this Mac" }
            if !report.captured.isEmpty {
                lines.append("\nWhen these devices are on another network, keep the bridge on and they'll appear in Xcode while they're online in Tailscale.")
            }
            alert.informativeText = lines.joined(separator: "\n")
        }
        present(alert)
    }

    @objc private func importDevices() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a devices.json from another copy of Xcode Tailscale Bridge."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try DeviceStore.importFile(at: url)
            bridge.restart()
            let alert = NSAlert()
            alert.messageText = "Imported \(count) device(s)"
            present(alert)
        } catch {
            present(NSAlert(error: error))
        }
    }

    @objc private func copyUDID(_ sender: NSMenuItem) {
        guard let udid = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(udid, forType: .string)
    }

    @objc private func removeDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? Device else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(device.name.displaySafe)?"
        alert.informativeText = "The bridge will stop advertising it. To add it back, capture it again on its network."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard present(alert) == .alertFirstButtonReturn else { return }
        do {
            try DeviceStore.remove(udid: device.udid)
            bridge.restart()
        } catch {
            present(NSAlert(error: error))
        }
    }

    @objc private func restartPairingService() {
        DispatchQueue.global().async { DeviceCtl.restartPairingService() }
    }

    @objc private func showLog() {
        if !FileManager.default.fileExists(atPath: Log.url.path) { Log.info("Log opened") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSWorkspace.shared.open(Log.url) }
    }

    private static let projectURL = URL(string: "https://github.com/petejkim/xcode-tailscale-bridge")!

    /// The standard About panel: icon, name, version and copyright come from the bundle,
    /// plus a link to the project as the credits.
    @objc private func showAbout() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(string: "github.com/petejkim/xcode-tailscale-bridge", attributes: [
            .link: Self.projectURL,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: paragraph,
        ])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func showDevicesFile() {
        if FileManager.default.fileExists(atPath: DeviceStore.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([DeviceStore.url])
        } else {
            NSWorkspace.shared.open(DeviceStore.url.deletingLastPathComponent().deletingLastPathComponent())
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            present(NSAlert(error: error))
        }
        rebuildMenu()
    }

    @discardableResult
    private func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}
