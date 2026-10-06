import Foundation

/// Reads remotepairingd's unified log messages. These are undocumented and may change between Xcode releases.
enum PairingLog {
    private static let resolvedPattern = try! NSRegularExpression(
        pattern: #"Resolved bonjour advert (\S+) to identity associated with udid (\S+)"#)
    private static let tunnelPredicate = #"process == "remotepairingd" AND (eventMessage CONTAINS "Got tunnel endpoint" OR eventMessage CONTAINS "Sending tunnel establish request")"#

    /// Bonjour identifier -> UDID, as remotepairingd matched adverts against its pairings.
    static func resolvedAdverts(last: String = "24h") -> [String: String] {
        let out = Shell.run("/usr/bin/log", ["show", "--last", last, "--style", "compact", "--predicate",
                                             #"process == "remotepairingd" AND eventMessage CONTAINS "Resolved bonjour advert""#]).stdout
        var map: [String: String] = [:]
        for line in out.split(separator: "\n") {
            if let groups = matches(resolvedPattern, String(line)) { map[groups[0]] = groups[1] }
        }
        return map
    }

    /// UDID -> the most recent tunnel port each device offered.
    static func lastTunnelPorts(last: String = "24h") -> [String: UInt16] {
        let out = Shell.run("/usr/bin/log", ["show", "--last", last, "--style", "compact", "--predicate", tunnelPredicate]).stdout
        var parser = TunnelLogParser()
        var ports: [String: UInt16] = [:]
        for line in out.split(separator: "\n") {
            if let (udid, port) = parser.feed(String(line)) { ports[udid] = port }
        }
        return ports
    }

    /// Streams tunnel offers as remotepairingd logs them.
    static func followTunnels(queue: DispatchQueue, onTunnel: @escaping (_ udid: String, _ port: UInt16) -> Void) throws -> LineStream {
        var parser = TunnelLogParser()
        return try LineStream("/usr/bin/log", ["stream", "--style", "compact", "--predicate", tunnelPredicate], queue: queue) { line in
            if let (udid, port) = parser.feed(line) { onTunnel(udid, port) }
        }
    }

    static func matches(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = regex.firstMatch(in: line, range: range) else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: line).map { String(line[$0]) } }
    }
}

/// Pairs `device-N (<UDID>): Sending tunnel establish request` with the
/// `Got tunnel endpoint: '<ip>%<if>:<port>'` line that follows it.
struct TunnelLogParser {
    private static let establish = try! NSRegularExpression(pattern: #"\(([0-9A-Fa-f-]{20,})\): Sending tunnel establish request"#)
    private static let endpoint = try! NSRegularExpression(pattern: #"Got tunnel endpoint: '[^']*:(\d+)'"#)
    private var lastEstablish: String?

    mutating func feed(_ line: String) -> (String, UInt16)? {
        if let groups = PairingLog.matches(Self.establish, line) {
            lastEstablish = groups[0]
        } else if let groups = PairingLog.matches(Self.endpoint, line), let udid = lastEstablish, let port = UInt16(groups[0]) {
            return (udid, port)
        }
        return nil
    }
}
