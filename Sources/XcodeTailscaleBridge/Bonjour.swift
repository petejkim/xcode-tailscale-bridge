import Darwin
import Foundation
import dnssd

private func check(_ error: DNSServiceErrorType, _ what: String) throws {
    if error != 0 { throw BridgeError("\(what) failed (DNSServiceErrorType \(error))") }
}

/// Publishes a service for another host, like `dns-sd -i <interface> -P`: an A record for
/// `host` -> `ipv4` plus the service's SRV/TXT records, on one interface only.
final class ProxyAdvertisement {
    private var connection: DNSServiceRef?
    private var service: DNSServiceRef?
    private var record: DNSRecordRef?

    /// Must be cancelled on `queue`.
    init(instance: String, type: String, port: UInt16, host: String, ipv4: String,
         txt: [String: String], interface: String, queue: DispatchQueue) throws {
        let interfaceIndex = if_nametoindex(interface)
        guard interfaceIndex != 0 else { throw BridgeError("No interface named \(interface)") }
        var address = in_addr()
        guard inet_pton(AF_INET, ipv4, &address) == 1 else { throw BridgeError("Bad IPv4 address \(ipv4)") }

        try check(DNSServiceCreateConnection(&connection), "DNSServiceCreateConnection")
        try check(DNSServiceSetDispatchQueue(connection, queue), "DNSServiceSetDispatchQueue")
        let recordError = withUnsafeBytes(of: &address) { bytes in
            DNSServiceRegisterRecord(connection, &record, DNSServiceFlags(kDNSServiceFlagsUnique), interfaceIndex, host,
                                     UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN), UInt16(bytes.count),
                                     bytes.baseAddress, 240, { _, _, _, error, _ in
                                         if error != 0 { Log.info("Bonjour host record registration failed (\(error))") }
                                     }, nil)
        }
        try check(recordError, "DNSServiceRegisterRecord")

        let txtData = Self.txtRecord(txt)
        let serviceError = txtData.withUnsafeBytes { bytes in
            DNSServiceRegister(&service, 0, interfaceIndex, instance, type, "local", host, port.bigEndian,
                               UInt16(bytes.count), bytes.baseAddress, { _, _, error, name, _, _, _ in
                                   if error != 0 { Log.info("Bonjour service registration failed (\(error))") }
                               }, nil)
        }
        try check(serviceError, "DNSServiceRegister")
        try check(DNSServiceSetDispatchQueue(service, queue), "DNSServiceSetDispatchQueue")
    }

    func cancel() {
        if let service { DNSServiceRefDeallocate(service) }
        if let connection { DNSServiceRefDeallocate(connection) }
        service = nil
        connection = nil
        record = nil
    }

    deinit { cancel() }

    /// Encodes TXT key=value pairs, keeping the order remotepairing devices use.
    static func txtRecord(_ txt: [String: String]) -> Data {
        let preferred = ["identifier", "authTag", "ver", "minVer", "flags"]
        let keys = preferred.filter { txt[$0] != nil } + txt.keys.filter { !preferred.contains($0) }.sorted()
        var data = Data()
        for key in keys {
            let entry = Data("\(key)=\(txt[key]!)".utf8).prefix(255)
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        return data
    }
}

/// Browses for instances of a service type and reports each one added.
final class BonjourBrowser {
    private var ref: DNSServiceRef?
    fileprivate let onFound: (_ name: String, _ interfaceIndex: UInt32) -> Void

    /// Must be cancelled on `queue`.
    init(type: String, queue: DispatchQueue, onFound: @escaping (_ name: String, _ interfaceIndex: UInt32) -> Void) throws {
        self.onFound = onFound
        let context = Unmanaged.passUnretained(self).toOpaque()
        try check(DNSServiceBrowse(&ref, 0, 0, type, "local", { _, flags, interfaceIndex, error, name, _, _, context in
            guard error == 0, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let name, let context else { return }
            Unmanaged<BonjourBrowser>.fromOpaque(context).takeUnretainedValue().onFound(String(cString: name), interfaceIndex)
        }, context), "DNSServiceBrowse")
        try check(DNSServiceSetDispatchQueue(ref, queue), "DNSServiceSetDispatchQueue")
    }

    func cancel() {
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
    }

    deinit { cancel() }
}

enum BonjourResolver {
    struct Record {
        let host: String
        let port: UInt16
        let txt: [String: String]
    }

    private final class Box {
        var record: Record?
        let done = DispatchSemaphore(value: 0)
    }

    /// Resolves one service instance. Blocks for up to `timeout`; don't call on the main thread.
    static func resolve(name: String, type: String, interfaceIndex: UInt32, timeout: TimeInterval) -> Record? {
        let queue = DispatchQueue(label: "bonjour-resolve")
        let box = Box()
        var ref: DNSServiceRef?
        let context = Unmanaged.passUnretained(box).toOpaque()
        let error = DNSServiceResolve(&ref, 0, interfaceIndex, name, type, "local", { _, _, _, error, _, host, port, txtLength, txt, context in
            guard error == 0, let host, let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            guard box.record == nil else { return }
            var hostName = String(cString: host)
            if hostName.hasSuffix(".") { hostName.removeLast() }
            let txtData = txt.map { Data(bytes: $0, count: Int(txtLength)) } ?? Data()
            box.record = BonjourResolver.Record(host: hostName, port: UInt16(bigEndian: port),
                                                txt: BonjourResolver.parseTXT(txtData))
            box.done.signal()
        }, context)
        guard error == 0, let ref else { return nil }
        DNSServiceSetDispatchQueue(ref, queue)
        _ = box.done.wait(timeout: .now() + timeout)
        queue.sync { DNSServiceRefDeallocate(ref) }
        return queue.sync { box.record }
    }

    static func parseTXT(_ data: Data) -> [String: String] {
        var txt: [String: String] = [:]
        var index = data.startIndex
        while index < data.endIndex {
            let length = Int(data[index])
            let start = data.index(after: index)
            let end = min(data.index(start, offsetBy: length, limitedBy: data.endIndex) ?? data.endIndex, data.endIndex)
            let entry = String(decoding: data[start..<end], as: UTF8.self)
            if let equals = entry.firstIndex(of: "=") {
                txt[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
            }
            index = end
        }
        return txt
    }
}
