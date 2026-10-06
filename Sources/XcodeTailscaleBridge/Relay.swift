import Foundation
import Network

/// Listens on one local IP and port and hands each accepted connection to `onConnection`.
///
/// The IP is this Mac's LAN address, so other machines on the network could connect too.
/// Only connections from this Mac itself (where remotepairingd runs) are accepted; anything
/// else would otherwise be relayed to the device over Tailscale.
final class PortListener {
    private let listener: NWListener

    init(ip: String, port: UInt16, queue: DispatchQueue, onConnection: @escaping (NWConnection) -> Void,
         onFailure: @escaping () -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!)
        // Don't fail on connections from a previous run still in TIME_WAIT.
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        let localAddress = IPv4Address(ip)
        listener.newConnectionHandler = { connection in
            guard case .hostPort(let host, _) = connection.endpoint, case .ipv4(let address) = host,
                  address.rawValue == localAddress?.rawValue else {
                RefusalLog.note(from: connection.endpoint, port: port)
                connection.cancel()
                return
            }
            onConnection(connection)
        }
        listener.stateUpdateHandler = { [listener] state in
            if case .failed(let error) = state {
                Log.info("[\(port)] listen failed: \(error)")
                listener.cancel()
                onFailure()
            }
        }
        listener.start(queue: queue)
    }

    func cancel() { listener.cancel() }
}

/// Logs refused connections without flooding the log. Another Mac on the network that's
/// paired with the same device sees the advert and retries every few seconds, so only the
/// first refusal from each address is logged, then a count at most every 10 minutes.
enum RefusalLog {
    private static let interval: TimeInterval = 600
    private static let queue = DispatchQueue(label: "refusal-log")
    private static var sources: [String: (lastLogged: Date, unlogged: Int)] = [:]

    static func note(from endpoint: NWEndpoint, port: UInt16) {
        let address: String
        if case .hostPort(let host, _) = endpoint { address = "\(host)" } else { address = "\(endpoint)" }
        queue.async {
            let now = Date()
            guard let source = sources[address] else {
                sources[address] = (now, 0)
                Log.info("[\(port)] refused connection from \(address): not from this Mac. "
                         + "Further refusals from it are counted every 10 minutes.")
                return
            }
            if now.timeIntervalSince(source.lastLogged) >= interval {
                Log.info("Refused \(source.unlogged + 1) more connection(s) from \(address) since the last report")
                sources[address] = (now, 0)
            } else {
                sources[address] = (source.lastLogged, source.unlogged + 1)
            }
        }
    }
}

/// Pipes one accepted connection to a remote host and port, in both directions.
final class Forwarder {
    private let inbound: NWConnection
    private let outbound: NWConnection
    private let queue: DispatchQueue
    private var closed = false
    var onReady: (() -> Void)?
    var onClose: (() -> Void)?

    init(inbound: NWConnection, host: String, port: UInt16, queue: DispatchQueue) {
        self.inbound = inbound
        // Default parameters: routed normally, so traffic to a Tailscale IP goes through Tailscale.
        outbound = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.queue = queue
    }

    func start() {
        outbound.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.pipe(from: self.inbound, to: self.outbound)
                self.pipe(from: self.outbound, to: self.inbound)
            case .waiting(let error), .failed(let error):
                Log.info("connection to \(self.outbound.endpoint) failed: \(error)")
                self.close()
            default:
                break
            }
        }
        inbound.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        inbound.start(queue: queue)
        outbound.start(queue: queue)
    }

    private func pipe(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError != nil || isComplete {
                        self.close()
                    } else {
                        self.pipe(from: source, to: destination)
                    }
                })
            } else if isComplete || error != nil {
                self.close()
            } else {
                self.pipe(from: source, to: destination)
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        inbound.stateUpdateHandler = nil
        outbound.stateUpdateHandler = nil
        inbound.cancel()
        outbound.cancel()
        onClose?()
        onClose = nil
        onReady = nil
    }
}
