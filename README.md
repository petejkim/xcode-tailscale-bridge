# Xcode Tailscale Bridge

A small macOS menu bar app that lets Xcode use your iPhone or iPad wirelessly **from a different network**, over [Tailscale](https://tailscale.com).

Xcode's wireless debugging only finds devices on the same local network as the Mac. That rules out a Mac VM in NAT mode, a build machine in another room or office, or a phone that's simply on a different Wi-Fi or on cellular. If the Mac and the device are both on your tailnet, this app makes the device show up in Xcode as if it were on the same network. You can then build, install, run and debug as usual.

> This relies on undocumented behaviour of Xcode's pairing service. It's tested with Xcode 27 and iOS 27, and a future Xcode or iOS update could break it.

## Requirements

- **Mac:** macOS 14 or later, with Xcode installed.
- **Tailscale:** installed and connected on both the Mac and the iOS device.
- **Pairing:** the device must already be paired with this Mac for wireless debugging. Pair it once over USB or on the same network: Xcode → Window → Devices and Simulators, with **Connect via network** turned on.

## Build and install

**In Xcode:** open `XcodeTailscaleBridge.xcodeproj` and press Run (⌘R). The project is set to "Sign to Run Locally", so it builds without an Apple Developer account. To sign with your own team, change it under the target's Signing & Capabilities.

**From the command line:**

```sh
git clone https://github.com/petejkim/xcode-tailscale-bridge.git && cd xcode-tailscale-bridge
scripts/build-app.sh            # universal Release build into build/
open "build/Xcode Tailscale Bridge.app"
```

`scripts/build-app.sh debug` makes a debug build. To keep the app, move it to `/Applications`.

**With SwiftPM:** `swift build` and `swift run XcodeTailscaleBridge --run` also work, for quick command-line builds. That produces a bare executable rather than an app bundle, so use the Xcode project or the script for the menu bar app.

Both build from the same sources in `Sources/XcodeTailscaleBridge/`. The Xcode project picks up new files there automatically.

**The first time** the app runs, macOS asks whether to **allow incoming connections**. Click **Allow**: the app relays Xcode's connections through local ports. If you click Deny, the device stays unavailable in Xcode. You may be asked again after rebuilding, because the app is signed only for this Mac.

## Usage

1. **Capture each device once.** With the device on the **same network** as the Mac and awake, choose **Capture Devices on This Network…** from the menu. This saves the device's pairing record, which Xcode needs to recognise it. Do it once per device, and again after re-pairing.
2. **Leave the bridge on.** When the device is on any other network and online in Tailscale, it appears in Xcode within about 15 seconds. The menu shows each device's status:

   | Status | Meaning |
   |---|---|
   | ⚪ offline in Tailscale | The device isn't online in your tailnet |
   | 🟡 waiting for Xcode | Advertised to Xcode; no connection yet |
   | 🔵 available | Xcode is connected to the device's pairing service |
   | 🟢 connected | Xcode has a tunnel to the device (installing, debugging, …) |

**Matching devices to Tailscale:** each device is looked up in Tailscale by its device name, lowercased with every other character replaced by `-` ("My iPhone 16" → `my-iphone-16`). If the device has a different name in Tailscale, use **Troubleshooting → Show Devices File** and set that device's `tailscale` field to its name in `tailscale status`.

### Menu reference

- **Turn Bridge On / Off:** remembered across launches.
- **Capture Devices on This Network…:** see step 1 above.
- **Import devices.json…:** imports devices captured by another copy of this app, for example on another Mac.
- **Device ▸ Remove Device…:** stops advertising a device.
- **Troubleshooting:**
  - **Restart Pairing Service:** restarts Xcode's `remotepairingd` and `CoreDeviceService`, which clears a device stuck in reconnect backoff.
  - **Show Log:** opens `~/Library/Logs/XcodeTailscaleBridge.log`.
  - **Show Devices File:** reveals `~/Library/Application Support/XcodeTailscaleBridge/devices.json`.
- **Launch at Login:** available when running from the `.app`.

### Command line

The app's binary has three headless modes, useful over SSH or for debugging:

```sh
B="build/Xcode Tailscale Bridge.app/Contents/MacOS/Xcode Tailscale Bridge"
"$B" --capture     # capture devices on this network
"$B" --run         # run the bridge without the menu bar item (Ctrl-C to stop)
"$B" --diagnose    # print what the app can see: interface, Tailscale peers, paired devices, captured devices
```

## How it works

Xcode (through `remotepairingd`, its pairing service) discovers wireless devices by their Bonjour announcement, `_remotepairing._tcp`. Bonjour is multicast and doesn't cross networks or Tailscale, so a device on another network is never found, even when it's reachable over Tailscale.

Faking the announcement isn't enough. These details came out of investigating `remotepairingd`'s logs:

1. **The announcement is authenticated.** Its TXT record carries an `authTag` that `remotepairingd` checks against the stored pairing, so it has to be the device's real announcement. Devices change their announced identity about every hour, but an earlier one keeps being accepted while the pairing is unchanged. That's why one capture per device is enough.
2. **Connections are pinned to the interface the announcement arrived on.** `remotepairingd` ignores announcements on the Tailscale interface or registered as local-only. When an announcement arrives on the primary interface (e.g. `en0`), every connection is pinned to that interface, so traffic to the device's Tailscale IP never goes through Tailscale.
3. **The tunnel port changes on every attempt.** After the pairing handshake, the device opens a CoreDevice tunnel on a new TCP port for each attempt, chosen sequentially.

So the app:

- **Advertises at the Mac's own address.** It publishes each captured announcement on the primary interface, pointing at the Mac's own IP and a local port (42000, 42001, …). Connections to your own address go through loopback, so pinning them to the interface is harmless.
- **Relays to the device.** It forwards those connections to the device's Tailscale IP over a normally routed connection.
- **Follows the tunnel ports.** It watches `remotepairingd`'s log for the tunnel port each device offers, and listens on the next 20 ports ahead of time to relay them too.
- **Tracks Tailscale.** It checks `tailscale status` every 15 seconds and only advertises devices that are online. It restarts itself when the Mac's network changes.

**Cleanup on exit:** quitting, or a SIGTERM, withdraws the announcements and closes every relayed connection. Even after a force quit (SIGKILL), the system's Bonjour daemon drops the announcements as soon as the app's connection to it closes. The app's helper `log stream` process stops itself within a few seconds.

## Troubleshooting

- **Device stays "waiting for Xcode" or unavailable:**
  - Check that you allowed incoming connections. Look in System Settings → Network → Firewall → Options.
  - Try **Troubleshooting → Restart Pairing Service**.
- **"tracking as unauth device" in `remotepairingd`'s log:** the captured record is no longer accepted, usually after re-pairing. Capture the device again on its network. To view the log (in zsh, `log` is a builtin, so use the full path):
  ```sh
  /usr/bin/log show --last 5m --style compact --predicate 'process == "remotepairingd"'
  ```
- **"devicectl not found":** the app also looks in `/Applications/Xcode*.app`. Otherwise run `sudo xcode-select -s /Applications/Xcode.app`.
- **Capture finds nothing:** the device has to be awake and on the same network as the Mac.
- **Device never shows up:** check that the `tailscale` field in the devices file matches the device's name in `tailscale status`.

## Limitations

- **Undocumented behaviour:** the app depends on the format of the Bonjour record, the wording of `remotepairingd`'s log messages, and sequential tunnel ports. Any of them could change in a future Xcode or iOS release.
- **IPv4 only:** the Mac's primary interface needs an IPv4 address.
- **Not sandboxed:** the app runs system tools (`log`, `xcrun devicectl`, the Tailscale CLI), so it can't be sandboxed or distributed through the Mac App Store.
- **Unaffiliated:** this project isn't affiliated with Apple or Tailscale. Xcode is a trademark of Apple Inc., and Tailscale is a trademark of Tailscale Inc.

## Background

This started from the idea in [iPhone remote debugging over VPN connection](https://stackoverflow.com/questions/49267354/iphone-remote-debugging-over-vpn-connection) on Stack Overflow: fake the device's Bonjour announcement at its VPN address. With Xcode 27 / iOS 27 that no longer works on its own, for the reasons above.

## License

[MIT](LICENSE) © Pete Kim ([@petejkim](https://github.com/petejkim))
