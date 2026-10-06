import AppKit

if CommandLine.arguments.contains("--diagnose") {
    Diagnostics.run()
    exit(0)
}

if CommandLine.arguments.contains("--capture") {
    do {
        let report = try Capture.run()
        for device in report.captured { print("Captured \(device.name) (\(device.udid)), Tailscale name \(device.tailscale)") }
        for host in report.notPaired { print("Skipped \(host): not paired with this Mac") }
        for name in report.missing { print("Not seen: \(name). Is it awake and on this network?") }
        print("Devices file: \(DeviceStore.url.path)")
        exit(0)
    } catch {
        print(error.localizedDescription)
        exit(1)
    }
}

if CommandLine.arguments.contains("--run") {
    // Headless: run the bridge without the menu bar item. Ctrl-C or SIGTERM to stop.
    let bridge = Bridge()
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            bridge.shutdown()
            exit(0)
        }
        source.resume()
        _ = Unmanaged.passRetained(source)
    }
    bridge.start()
    dispatchMain()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
