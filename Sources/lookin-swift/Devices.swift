import Foundation

/// Which LookinServer the tools should connect to.
enum DeviceTarget: Equatable {
    case auto                 // simulator first, then first USB device
    case simulator            // booted simulator only
    case device(udid: String) // a specific USB device
}

/// Holds the current connection target (set via lookin_connect_device) and
/// resolves it to a live socket for the Peertalk client.
final class DeviceSelection {
    static let shared = DeviceSelection()
    var target: DeviceTarget = .auto

    struct DeviceInfo {
        let udid: String
        let name: String
        let type: String // "simulator" | "physical"
    }

    /// Booted simulators (via simctl) + USB devices (via usbmux).
    func list() -> [DeviceInfo] {
        var result: [DeviceInfo] = []
        for sim in Self.bootedSimulators() {
            result.append(DeviceInfo(udid: sim.udid, name: sim.name, type: "simulator"))
        }
        if let usb = try? UsbMux.listDevices() {
            for d in usb {
                result.append(DeviceInfo(udid: d.udid, name: d.udid, type: "physical"))
            }
        }
        return result
    }

    // Caches so we don't re-probe / re-enumerate on every call. deviceId is the
    // Mac↔device USB link id (stable across app restarts; only invalid on
    // unplug). autoRoute remembers whether simulator or which device answered
    // last, so auto mode skips the simulator probes on a device-only setup.
    private var deviceIdCache: [String: Int] = [:]
    private enum Route { case simulator; case device(Int) }
    private var autoRoute: Route?

    /// Clear connection caches (call when a connection unexpectedly fails).
    func invalidateCaches() {
        deviceIdCache.removeAll()
        autoRoute = nil
    }

    /// Connect to LookinServer (simulator ports, or device ports via usbmux).
    func connect() throws -> Int32 {
        return try connect(simPorts: Array(Peertalk.simulatorPorts), devicePorts: Array(UsbMux.devicePorts))
    }

    /// Connect to an arbitrary `port` on the current target (the
    /// LookinServer-Control command channel on :47180).
    func connectPort(_ port: Int) throws -> Int32 {
        return try connect(simPorts: [port], devicePorts: [port])
    }

    // MARK: - Connect core

    private func connect(simPorts: [Int], devicePorts: [Int]) throws -> Int32 {
        switch target {
        case .simulator:
            return try connectSim(simPorts)
        case .device(let udid):
            return try connectDeviceUdid(udid, devicePorts)
        case .auto:
            return try connectAuto(simPorts: simPorts, devicePorts: devicePorts)
        }
    }

    private func connectAuto(simPorts: [Int], devicePorts: [Int]) throws -> Int32 {
        // Reuse the last good route first.
        if let route = autoRoute {
            switch route {
            case .simulator:
                if let fd = try? connectSim(simPorts) { return fd }
            case .device(let id):
                if let fd = try? connectDevicePorts(id, devicePorts) { return fd }
            }
            autoRoute = nil // stale — fall through to re-resolve
        }
        if let fd = try? connectSim(simPorts) { autoRoute = .simulator; return fd }
        if let devices = try? UsbMux.listDevices() {
            for d in devices {
                deviceIdCache[d.udid] = d.deviceId
                if let fd = try? connectDevicePorts(d.deviceId, devicePorts) {
                    autoRoute = .device(d.deviceId); return fd
                }
            }
        }
        throw LookinError.message("Cannot reach LookinServer. Start the app (with pod 'LookinServer', and 'LookinServer-Control' for taps) in a booted simulator, or connect a USB device and run it in the foreground.")
    }

    private func connectSim(_ ports: [Int]) throws -> Int32 {
        for port in ports {
            if let fd = try? Peertalk.connect(host: "127.0.0.1", port: port) { return fd }
        }
        throw LookinError.message("No LookinServer on a booted simulator. Is the app running in the foreground?")
    }

    private func connectDeviceUdid(_ udid: String, _ ports: [Int]) throws -> Int32 {
        // Try cached deviceId; on failure, refresh the map once and retry.
        if let id = deviceIdCache[udid], let fd = try? connectDevicePorts(id, ports) { return fd }
        for d in try UsbMux.listDevices() { deviceIdCache[d.udid] = d.deviceId }
        guard let id = deviceIdCache[udid] else {
            throw LookinError.message("USB device \(udid) not found. Run lookin_list_devices.")
        }
        return try connectDevicePorts(id, ports)
    }

    private func connectDevicePorts(_ deviceId: Int, _ ports: [Int]) throws -> Int32 {
        for port in ports {
            if let fd = try? UsbMux.connectToDevice(deviceId: deviceId, port: port) { return fd }
        }
        throw LookinError.message("Connected to device but no listener on ports \(ports.first ?? 0)-\(ports.last ?? 0) is open. Is the app in the foreground?")
    }

    private static func bootedSimulators() -> [(udid: String, name: String)] {
        guard let out = try? runSimctl() else { return [] }
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: Any] else { return [] }
        var result: [(String, String)] = []
        for (_, list) in devices {
            for dev in (list as? [[String: Any]]) ?? [] where (dev["state"] as? String) == "Booted" {
                if let udid = dev["udid"] as? String, let name = dev["name"] as? String {
                    result.append((udid, name))
                }
            }
        }
        return result
    }

    private static func runSimctl() throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["simctl", "list", "devices", "booted", "--json"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
