import Foundation

/// `XcodeTailscaleBridge --diagnose`: prints what the bridge can see, for troubleshooting.
enum Diagnostics {
    static func run() {
        let interface = LocalNetwork.primaryInterface()
        print("Primary interface: \(interface ?? "none") \(interface.flatMap(LocalNetwork.ipv4Address(of:)) ?? "")")
        print("Tailscale CLI: \(Tailscale.cliPath ?? "not found")")
        do {
            let peers = try Tailscale.onlinePeers()
            print("Online Tailscale peers: \(peers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
        } catch {
            print("Tailscale: \(error.localizedDescription)")
        }
        do {
            let paired = try DeviceCtl.pairedDevices()
            print("Paired devices: \(paired.map { "\($0.value) (\($0.key))" }.joined(separator: ", "))")
        } catch {
            print("devicectl: \(error.localizedDescription)")
        }
        let devices = DeviceStore.load()
        print("Captured devices (\(DeviceStore.url.path)):")
        for device in devices {
            print("  \(device.name) \(device.udid) tailscale=\(device.tailscale) identifier=\(device.identifier) captured=\(device.captured)")
        }
        print("Last tunnel ports: \(PairingLog.lastTunnelPorts())")
        print("Resolved adverts (24h): \(PairingLog.resolvedAdverts().count)")
    }
}
