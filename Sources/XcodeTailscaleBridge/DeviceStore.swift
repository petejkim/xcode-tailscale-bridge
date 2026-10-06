import Foundation

/// A paired iOS device and the Bonjour pairing record it broadcast on a shared network.
struct Device: Codable, Equatable {
    var udid: String
    var name: String
    /// Tailscale DNS label: the first part of `name.tailXXXX.ts.net`.
    var tailscale: String
    /// Stable ID of the Tailscale node first seen under that name. A different node taking
    /// the name later isn't trusted. Cleared by capturing the device again.
    var tailscaleNodeID: String?
    /// Bonjour instance name / TXT `identifier` of the captured record.
    var identifier: String
    /// Port of the device's pairing service.
    var port: Int
    /// TXT record of the captured `_remotepairing._tcp` advert (identifier, authTag, ...).
    var txt: [String: String]
    var captured: String

    /// Why this entry can't be used, or nil if it's valid. devices.json can be hand-edited
    /// or imported, so nothing in it is trusted.
    var problem: String? {
        if udid.isEmpty || udid.utf8.count > 64 { return "bad UDID" }
        if !(1...65535).contains(port) { return "port \(port) out of range" }
        if identifier.isEmpty || identifier.utf8.count > 63 { return "bad Bonjour identifier" }
        if !isDNSLabel(tailscale) { return "bad Tailscale name \"\(tailscale.displaySafe)\"" }
        if txt.contains(where: { $0.key.isEmpty || $0.key.contains("=") || "\($0.key)=\($0.value)".utf8.count > 255 }) {
            return "bad TXT record"
        }
        return nil
    }
}

/// A lowercase DNS label, as Tailscale uses in its names.
private func isDNSLabel(_ label: String) -> Bool {
    guard (1...63).contains(label.utf8.count), !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
    return label.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
}

enum DeviceStore {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("XcodeTailscaleBridge/devices.json")

    /// Each device gets its own local port, so keep the count well within range.
    static let maxDevices = 100

    /// The usable devices; invalid entries are left out (see `problems()`).
    static func load() -> [Device] {
        loadChecked().devices
    }

    /// Descriptions of entries in devices.json that `load()` leaves out.
    static func problems() -> [String] {
        loadChecked().problems
    }

    private static func loadChecked() -> (devices: [Device], problems: [String]) {
        guard let data = try? Data(contentsOf: url) else { return ([], []) }
        guard let all = try? JSONDecoder().decode([Device].self, from: data) else {
            return ([], ["\(url.lastPathComponent) can't be read as a list of devices"])
        }
        var devices: [Device] = []
        var problems: [String] = []
        for device in all {
            if let problem = device.problem {
                problems.append("skipping device \"\(device.name.displaySafe)\": \(problem)")
            } else if devices.count >= maxDevices {
                problems.append("skipping device \"\(device.name.displaySafe)\": more than \(maxDevices) devices")
            } else if !devices.contains(where: { $0.udid == device.udid }) {
                devices.append(device)
            }
        }
        return (devices, problems)
    }

    static func save(_ devices: [Device]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sorted = devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(sorted).write(to: url, options: .atomic)
    }

    /// Remembers which Tailscale node a device was first seen as.
    static func pin(udid: String, nodeID: String) throws {
        try save(load().map { device in
            var device = device
            if device.udid == udid { device.tailscaleNodeID = nodeID }
            return device
        })
    }

    /// Adds or replaces devices by UDID, keeping a hand-edited `tailscale` label.
    /// The Tailscale node pin is reset, so a recaptured device can be trusted on a new node.
    static func merge(_ new: [Device]) throws {
        var byUDID = Dictionary(load().map { ($0.udid, $0) }, uniquingKeysWith: { $1 })
        for var device in new {
            if let old = byUDID[device.udid] { device.tailscale = old.tailscale }
            byUDID[device.udid] = device
        }
        try save(Array(byUDID.values))
    }

    static func remove(udid: String) throws {
        try save(load().filter { $0.udid != udid })
    }

    /// Imports a devices.json written by another copy of this app. The whole file is rejected
    /// if any entry is invalid. Devices already here keep their Tailscale name and node, and
    /// imported devices are re-tied to a node the first time they're seen.
    static func importFile(at source: URL) throws -> Int {
        let imported: [Device]
        do {
            imported = try JSONDecoder().decode([Device].self, from: Data(contentsOf: source))
        } catch {
            throw BridgeError("\(source.lastPathComponent) isn't a devices.json file.")
        }
        let problems = imported.compactMap { device in device.problem.map { "\(device.name.displaySafe): \($0)" } }
        guard problems.isEmpty else {
            throw BridgeError("\(source.lastPathComponent) has invalid entries:\n" + problems.joined(separator: "\n"))
        }
        var byUDID = Dictionary(load().map { ($0.udid, $0) }, uniquingKeysWith: { $1 })
        for var device in imported {
            device.tailscaleNodeID = byUDID[device.udid]?.tailscaleNodeID
            if let existing = byUDID[device.udid] { device.tailscale = existing.tailscale }
            byUDID[device.udid] = device
        }
        guard byUDID.count <= maxDevices else { throw BridgeError("That would be more than \(maxDevices) devices.") }
        try save(Array(byUDID.values))
        return imported.count
    }
}

/// Device name -> the label Tailscale uses in its DNS name.
func tailscaleLabel(for name: String) -> String {
    let lowered = name.lowercased()
    var label = ""
    var lastWasDash = false
    for scalar in lowered.unicodeScalars {
        if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
            label.unicodeScalars.append(scalar)
            lastWasDash = false
        } else if !lastWasDash {
            label.append("-")
            lastWasDash = true
        }
    }
    return label.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}
