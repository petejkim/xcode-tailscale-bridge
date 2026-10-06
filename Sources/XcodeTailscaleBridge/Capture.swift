import Foundation

/// Saves the Bonjour pairing record of every paired device on the current network.
/// Run while the devices are on the same LAN as this Mac; once per device, again after re-pairing.
enum Capture {
    struct Report {
        var captured: [Device] = []
        var notPaired: [String] = []
        var missing: [String] = []
        /// Devices skipped because several adverts claimed to be them.
        var conflicts: [String] = []
    }

    /// Blocks for about `seconds` plus resolve time; don't call on the main thread.
    static func run(seconds: TimeInterval = 5) throws -> Report {
        // Listing devices also wakes remotepairingd, which has to see the adverts to match them to UDIDs.
        let paired = try DeviceCtl.pairedDevices()

        let queue = DispatchQueue(label: "capture")
        var found: [String: UInt32] = [:]
        let browser = try queue.sync {
            try BonjourBrowser(type: Bridge.serviceType, queue: queue) { name, interfaceIndex in
                if found[name] == nil { found[name] = interfaceIndex }
            }
        }
        Thread.sleep(forTimeInterval: seconds)
        let names = queue.sync { () -> [String: UInt32] in
            browser.cancel()
            return found
        }
        guard !names.isEmpty else {
            throw BridgeError("No \(Bridge.serviceType) adverts seen. Is this Mac on the same network as the devices?")
        }

        let adverts = PairingLog.resolvedAdverts()
        var report = Report()
        var best: [String: (device: Device, seen: Int)] = [:]
        let timestamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.string(from: Date())
        }()
        var claims: [String: [(name: String, record: BonjourResolver.Record)]] = [:]
        for (name, interfaceIndex) in names {
            guard let record = BonjourResolver.resolve(name: name, type: Bridge.serviceType,
                                                       interfaceIndex: interfaceIndex, timeout: 3),
                  !record.host.hasPrefix("tsrelay-") else { continue }
            claims[record.txt["identifier"] ?? name, default: []].append((name, record))
        }
        var conflicted: Set<String> = []
        for (identifier, candidates) in claims {
            guard let advert = adverts[identifier], let deviceName = paired[advert.udid] else {
                report.notPaired += candidates.map(\.record.host)
                continue
            }
            // Anyone on the network can copy a device's advert. A real device names its instance
            // after its identifier, so if several adverts claim one identifier, only trust that one.
            let trusted = candidates.count == 1 ? candidates : candidates.filter { $0.name == identifier }
            guard trusted.count == 1, let (_, record) = trusted.first else {
                Log.info("Capture: \(candidates.count) adverts claim to be \(deviceName) (\(identifier)); skipping")
                conflicted.insert(advert.udid)
                continue
            }
            if candidates.count > 1 {
                Log.info("Capture: ignoring \(candidates.count - 1) other advert(s) claiming to be \(deviceName)")
            }
            let device = Device(udid: advert.udid, name: deviceName, tailscale: tailscaleLabel(for: deviceName),
                                identifier: identifier, port: Int(record.port), txt: record.txt, captured: timestamp)
            // A device can briefly advertise two identities while rotating; keep the latest one.
            if (best[advert.udid]?.seen ?? -1) < advert.seen { best[advert.udid] = (device, advert.seen) }
        }
        report.captured = best.values.map(\.device).sorted { $0.name < $1.name }
        report.conflicts = paired.filter { conflicted.contains($0.key) && best[$0.key] == nil }.map(\.value).sorted()
        report.missing = paired.filter { best[$0.key] == nil && !conflicted.contains($0.key) }.map(\.value).sorted()
        if !report.captured.isEmpty { try DeviceStore.merge(report.captured) }
        for device in report.captured { Log.info("Captured \(device.name) (\(device.udid))") }
        return report
    }
}
