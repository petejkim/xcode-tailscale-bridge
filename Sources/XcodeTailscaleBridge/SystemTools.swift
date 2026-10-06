import Darwin
import Foundation
import SystemConfiguration

enum DeviceCtl {
    /// Environment for xcrun that finds devicectl even if xcode-select points at the Command Line Tools.
    private static func xcrunEnvironment() throws -> [String: String]? {
        if Shell.run("/usr/bin/xcrun", ["--find", "devicectl"]).status == 0 { return nil }
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        for app in apps.filter({ $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }).sorted() {
            var env = ProcessInfo.processInfo.environment
            env["DEVELOPER_DIR"] = "/Applications/\(app)/Contents/Developer"
            if Shell.run("/usr/bin/xcrun", ["--find", "devicectl"], environment: env).status == 0 { return env }
        }
        throw BridgeError("devicectl not found. Install Xcode, or run: sudo xcode-select -s /Applications/Xcode.app")
    }

    /// UDID -> device name for every physical device paired with this Mac.
    static func pairedDevices() throws -> [String: String] {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: path) }
        let result = Shell.run("/usr/bin/xcrun", ["devicectl", "list", "devices", "--json-output", path.path],
                               environment: try xcrunEnvironment())
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]] else {
            let message = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeError("devicectl failed: \(message)")
        }
        var paired: [String: String] = [:]
        for device in devices {
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = device["connectionProperties"] as? [String: Any] ?? [:]
            let properties = device["deviceProperties"] as? [String: Any] ?? [:]
            guard hardware["reality"] as? String == "physical",
                  connection["pairingState"] as? String == "paired",
                  let udid = hardware["udid"] as? String else { continue }
            paired[udid] = properties["name"] as? String ?? udid
        }
        return paired
    }

    /// Restarts the daemons that track devices, clearing any reconnect backoff.
    /// Both run as the current user and relaunch on demand.
    static func restartPairingService() {
        Shell.run("/usr/bin/pkill", ["-x", "remotepairingd"])
        Shell.run("/usr/bin/pkill", ["-x", "CoreDeviceService"])
    }
}

enum Tailscale {
    private static let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    static var cliPath: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Peer {
        /// Tailscale IP, IPv4 preferred.
        let ip: String
        /// Stable node ID, which survives renames and IP changes.
        let nodeID: String
    }

    /// Tailscale DNS label -> peer, for every online peer in this Mac's own tailnet.
    /// Nodes shared in from other tailnets are left out: their names aren't ours to trust.
    static func onlinePeers() throws -> [String: Peer] {
        guard let cli = cliPath else { throw BridgeError("Tailscale CLI not found. Is Tailscale installed?") }
        // The Mac app's binary is both the GUI and the CLI, and without TERM it assumes it was
        // opened as the GUI ("The Tailscale GUI failed to start"). Apps launched from Finder or
        // the Dock have no TERM, so set one.
        var environment = ProcessInfo.processInfo.environment
        if environment["TERM"] == nil { environment["TERM"] = "dumb" }
        let result = Shell.run(cli, ["status", "--json"], environment: environment)
        guard let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else {
            let output = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeError("tailscale status failed (exit \(result.status)): \(output.isEmpty ? "no output" : String(output.prefix(200)))")
        }
        guard let suffix = json["MagicDNSSuffix"] as? String, !suffix.isEmpty else {
            throw BridgeError("tailscale status has no tailnet name (state: \(json["BackendState"] as? String ?? "unknown"))")
        }
        var online: [String: Peer] = [:]
        for case let peer as [String: Any] in (json["Peer"] as? [String: Any] ?? [:]).values {
            guard peer["Online"] as? Bool == true, peer["ShareeNode"] as? Bool != true,
                  let nodeID = peer["ID"] as? String, !nodeID.isEmpty,
                  let ips = peer["TailscaleIPs"] as? [String], let first = ips.first,
                  let dnsName = peer["DNSName"] as? String, dnsName.hasSuffix(".\(suffix).") else { continue }
            let label = String(dnsName.dropLast(suffix.count + 2))
            guard !label.isEmpty, !label.contains(".") else { continue }
            online[label] = Peer(ip: ips.first { $0.contains(".") } ?? first, nodeID: nodeID)
        }
        return online
    }
}

enum LocalNetwork {
    /// Which network the Mac is on. Two Wi-Fi networks can hand out the same IP,
    /// so the router's address is part of it too.
    struct Identity: Equatable {
        let interface: String
        let ip: String
        let router: String?
    }

    static func current() -> Identity? {
        guard let interface = primaryInterface(), let ip = ipv4Address(of: interface) else { return nil }
        return Identity(interface: interface, ip: ip, router: globalIPv4()?["Router"] as? String)
    }

    /// The interface carrying the default route, ignoring tunnels (e.g. a Tailscale exit node).
    static func primaryInterface() -> String? {
        guard let name = globalIPv4()?["PrimaryInterface"] as? String else { return nil }
        if name.hasPrefix("utun") { return ipv4Address(of: "en0") != nil ? "en0" : nil }
        return name
    }

    /// This Mac's Bonjour host name (System Settings → General → Sharing → Local hostname).
    static func localHostName() -> String {
        (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? "mac"
    }

    private static func globalIPv4() -> [String: Any]? {
        guard let store = SCDynamicStoreCreate(nil, "XcodeTailscaleBridge" as CFString, nil, nil) else { return nil }
        return SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
    }

    static func ipv4Address(of interface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard String(cString: entry.ifa_name) == interface,
                  let addr = entry.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
