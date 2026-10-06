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
}

enum DeviceStore {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("XcodeTailscaleBridge/devices.json")

    static func load() -> [Device] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Device].self, from: data)) ?? []
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

    /// Imports a devices.json written by another copy of this app.
    static func importFile(at source: URL) throws -> Int {
        let devices = try JSONDecoder().decode([Device].self, from: Data(contentsOf: source))
        var byUDID = Dictionary(load().map { ($0.udid, $0) }, uniquingKeysWith: { $1 })
        for device in devices { byUDID[device.udid] = device }
        try save(Array(byUDID.values))
        return devices.count
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
