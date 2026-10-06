import Foundation
import Network

/// Makes captured devices available to Xcode while they're online in Tailscale.
///
/// remotepairingd only accepts a device's Bonjour record on a real interface, pins its
/// connections to that interface, and checks the record's authTag against the stored
/// pairing. So each device's captured record is advertised on the primary interface,
/// pointing at this Mac's own address, and connections to it are relayed to the device's
/// Tailscale IP: first the pairing control channel, then the CoreDevice tunnel, whose
/// port the device picks per attempt. Devices hand those out sequentially, so the bridge
/// follows remotepairingd's log and listens on the next few ports ahead of time.
final class Bridge {
    static let controlPortBase: UInt16 = 42000
    static let lookahead: UInt16 = 20
    static let pollInterval: TimeInterval = 15
    static let serviceType = "_remotepairing._tcp"

    enum State: Equatable {
        case stopped
        case running
        case failed(String)
    }

    struct DeviceStatus {
        let device: Device
        let tailscaleIP: String?
        let controlConnections: Int
        let tunnelConnections: Int
    }

    struct Status {
        var state: State = .stopped
        var interface: String?
        var localIP: String?
        var warning: String?
        var devices: [DeviceStatus] = []
    }

    /// Called on the main queue whenever the status changes.
    var onChange: ((Status) -> Void)?

    private enum Kind { case control, tunnel }

    private final class Slot {
        let device: Device
        let controlPort: UInt16
        var ip: String?
        var advertisement: ProxyAdvertisement?
        var controlConnections = 0
        var tunnelConnections = 0

        init(device: Device, controlPort: UInt16) {
            self.device = device
            self.controlPort = controlPort
        }
    }

    private let queue = DispatchQueue(label: "bridge")
    private var enabled = false
    private var state = State.stopped
    private var interface: String?
    private var localIP: String?
    private var warning: String?
    private var slots: [String: Slot] = [:]
    private var order: [String] = []
    private var listeners: [UInt16: PortListener] = [:]
    private var window: [UInt16: Set<String>] = [:]
    private var owner: [UInt16: String] = [:]
    private var forwarders: [ObjectIdentifier: Forwarder] = [:]
    private var follower: LineStream?
    private var timer: DispatchSourceTimer?
    /// Bumped on every teardown so late async results from a previous run are ignored.
    private var generation = 0

    // MARK: Public API

    func start() {
        queue.async {
            self.enabled = true
            self.startTimer()
            self.setUp()
        }
    }

    func stop() {
        queue.async {
            self.enabled = false
            self.timer?.cancel()
            self.timer = nil
            self.tearDown()
            self.state = .stopped
            self.publish()
        }
    }

    /// Re-reads devices.json and the network.
    func restart() {
        queue.async {
            guard self.enabled else { return }
            self.tearDown()
            self.setUp()
        }
    }

    /// Withdraws all adverts before the app quits.
    func shutdown() {
        queue.sync {
            self.enabled = false
            self.timer?.cancel()
            self.tearDown()
        }
    }

    // MARK: Lifecycle

    private func setUp() {
        guard let interface = LocalNetwork.primaryInterface(), let ip = LocalNetwork.ipv4Address(of: interface) else {
            state = .failed("No network connection")
            publish()
            return
        }
        self.interface = interface
        localIP = ip
        let devices = DeviceStore.load()
        for (index, device) in devices.enumerated() {
            let slot = Slot(device: device, controlPort: Self.controlPortBase + UInt16(index))
            slots[device.udid] = slot
            order.append(device.udid)
            listen(on: slot.controlPort) { [weak self] connection in
                self?.forward(connection, udid: device.udid, remotePort: UInt16(device.port), kind: .control)
            }
        }
        state = .running
        Log.info("Bridge started on \(interface) (\(ip)) with \(devices.count) device(s)")
        publish()
        guard !devices.isEmpty else { return }

        let generation = self.generation
        DispatchQueue.global().async {
            let lastPorts = PairingLog.lastTunnelPorts()
            self.queue.async {
                guard generation == self.generation else { return }
                for (udid, port) in lastPorts where self.slots[udid] != nil {
                    self.expectTunnels(for: udid, after: port)
                }
            }
        }
        do {
            follower = try PairingLog.followTunnels(queue: queue) { [weak self] udid, port in
                self?.tunnelOffered(udid: udid, port: port)
            }
        } catch {
            Log.info("Can't follow remotepairingd's log: \(error.localizedDescription)")
        }
        pollTailscale()
    }

    private func tearDown() {
        generation += 1
        for slot in slots.values { slot.advertisement?.cancel() }
        for listener in listeners.values { listener.cancel() }
        for forwarder in Array(forwarders.values) { forwarder.close() }
        follower?.stop()
        follower = nil
        slots = [:]
        order = []
        listeners = [:]
        window = [:]
        owner = [:]
        forwarders = [:]
        interface = nil
        localIP = nil
        warning = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard enabled else { return }
        let interface = LocalNetwork.primaryInterface()
        let ip = interface.flatMap(LocalNetwork.ipv4Address(of:))
        if case .failed = state {
            if ip != nil { tearDown(); setUp() }
        } else if interface != self.interface || ip != localIP {
            Log.info("Network changed; restarting")
            tearDown()
            setUp()
        } else {
            pollTailscale()
        }
    }

    // MARK: Tailscale

    private func pollTailscale() {
        let generation = self.generation
        DispatchQueue.global().async {
            let result = Result { try Tailscale.onlinePeers() }
            self.queue.async {
                guard generation == self.generation else { return }
                switch result {
                case .success(let online):
                    self.warning = nil
                    self.apply(online: online)
                case .failure(let error):
                    if self.warning != error.localizedDescription { Log.info(error.localizedDescription) }
                    self.warning = error.localizedDescription
                }
                self.publish()
            }
        }
    }

    private func apply(online: [String: String]) {
        guard let interface, let localIP else { return }
        for udid in order {
            guard let slot = slots[udid] else { continue }
            let ip = online[slot.device.tailscale]
            slot.ip = ip
            if let ip, slot.advertisement == nil {
                do {
                    slot.advertisement = try ProxyAdvertisement(
                        instance: slot.device.identifier, type: Self.serviceType, port: slot.controlPort,
                        host: "tsrelay-\(slot.controlPort).local", ipv4: localIP, txt: slot.device.txt,
                        interface: interface, queue: queue)
                    Log.info("\(slot.device.name) online at \(ip); advertising")
                } catch {
                    Log.info("\(slot.device.name): can't advertise: \(error.localizedDescription)")
                }
            } else if ip == nil, let advertisement = slot.advertisement {
                advertisement.cancel()
                slot.advertisement = nil
                Log.info("\(slot.device.name) went offline; stopped advertising")
            }
        }
    }

    // MARK: Relaying

    private func listen(on port: UInt16, onConnection: @escaping (NWConnection) -> Void) {
        guard listeners[port] == nil, let localIP else { return }
        do {
            listeners[port] = try PortListener(ip: localIP, port: port, queue: queue, onConnection: onConnection)
        } catch {
            Log.info("[\(port)] listen failed: \(error.localizedDescription)")
        }
    }

    private func forward(_ connection: NWConnection, udid: String, remotePort: UInt16, kind: Kind) {
        guard let slot = slots[udid], let ip = slot.ip else {
            Log.info("[\(remotePort)] \(slots[udid]?.device.name ?? udid) is offline")
            connection.cancel()
            return
        }
        let forwarder = Forwarder(inbound: connection, host: ip, port: remotePort, queue: queue)
        let id = ObjectIdentifier(forwarder)
        forwarders[id] = forwarder
        var counted = false
        forwarder.onReady = { [weak self, weak slot] in
            guard let self, let slot else { return }
            counted = true
            switch kind {
            case .control: slot.controlConnections += 1
            case .tunnel: slot.tunnelConnections += 1
            }
            Log.info("[\(remotePort)] \(slot.device.name) connected")
            self.publish()
        }
        forwarder.onClose = { [weak self, weak slot] in
            guard let self else { return }
            self.forwarders[id] = nil
            if counted, let slot {
                switch kind {
                case .control: slot.controlConnections -= 1
                case .tunnel: slot.tunnelConnections -= 1
                }
                Log.info("[\(remotePort)] \(slot.device.name) closed")
            }
            self.publish()
        }
        forwarder.start()
    }

    private func tunnelOffered(udid: String, port: UInt16) {
        guard let slot = slots[udid] else { return }
        Log.info("\(slot.device.name) offered tunnel port \(port)")
        owner[port] = udid
        listenForTunnel(on: port)
        expectTunnels(for: udid, after: port)
    }

    private func listenForTunnel(on port: UInt16) {
        listen(on: port) { [weak self] connection in self?.tunnelConnection(connection, port: port, attempt: 0) }
    }

    /// Listens on the ports this device's next tunnel attempts will likely use,
    /// and stops listening on ports it has moved past.
    private func expectTunnels(for udid: String, after port: UInt16) {
        for (p, udids) in window where p < port && udids.contains(udid) {
            window[p]?.remove(udid)
            if window[p]?.isEmpty == true, owner[p] == nil || owner[p] == udid {
                window[p] = nil
                listeners.removeValue(forKey: p)?.cancel()
            }
        }
        let last = min(Int(port) + Int(Self.lookahead), Int(UInt16.max))
        guard Int(port) < last else { return }
        for p in (port + 1)...UInt16(last) {
            window[p, default: []].insert(udid)
            listenForTunnel(on: p)
        }
    }

    private func tunnelConnection(_ connection: NWConnection, port: UInt16, attempt: Int) {
        // The log line naming the port usually lands just before the connection; wait for it briefly.
        if let udid = owner[port] {
            forward(connection, udid: udid, remotePort: port, kind: .tunnel)
        } else if attempt < 10 {
            queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.tunnelConnection(connection, port: port, attempt: attempt + 1)
            }
        } else if let udids = window[port], udids.count == 1, let udid = udids.first {
            forward(connection, udid: udid, remotePort: port, kind: .tunnel)
        } else {
            Log.info("[\(port)] can't tell which device this tunnel is for")
            connection.cancel()
        }
    }

    // MARK: Status

    private func publish() {
        var status = Status(state: state, interface: interface, localIP: localIP, warning: warning)
        status.devices = order.compactMap { slots[$0] }.map {
            DeviceStatus(device: $0.device, tailscaleIP: $0.ip,
                         controlConnections: $0.controlConnections, tunnelConnections: $0.tunnelConnections)
        }
        if state != .running { status.devices = DeviceStore.load().map { DeviceStatus(device: $0, tailscaleIP: nil, controlConnections: 0, tunnelConnections: 0) } }
        DispatchQueue.main.async { self.onChange?(status) }
    }
}
