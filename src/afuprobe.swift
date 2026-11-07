import Cocoa
import CoreBluetooth

// afuprobe: hunt for the AFU / 蚂蚁阿福 body-fat scale.
//
// Strategy:
//  1. passive scan, log EVERY advertisement (allowDuplicates) so short weigh-in
//     bursts are not lost;
//  2. flag candidates that look like an AFU scale:
//       - service data under 0xFC50            (AFU native protocol, k6.a parser)
//       - FE95 service data whose product id == 0x391F (14623, the ONLY product id
//         registered in AFUDeviceManagerConfig / ICDeviceManagerConfig)
//       - any local name containing afu / scale / 体脂 / 秤
//  3. for each new candidate: connect, enumerate GATT, subscribe to EVERY
//     notify/indicate characteristic, then log every value with a ms timestamp
//     (never writes, so the scale's state is untouched).
//
// usage: afuprobe <seconds> [scanOnly]
// env:   BLE_OUT (default /tmp/afuprobe.out)

let outPath = ProcessInfo.processInfo.environment["BLE_OUT"] ?? "/tmp/afuprobe.out"
FileManager.default.createFile(atPath: outPath, contents: nil)
let outFile = FileHandle(forWritingAtPath: outPath)
let df = DateFormatter(); df.dateFormat = "HH:mm:ss.SSS"
func emit(_ s: String) {
    let line = "[\(df.string(from: Date()))] \(s)"
    print(line); fflush(stdout)
    outFile?.seekToEndOfFile(); outFile?.write((line + "\n").data(using: .utf8)!)
}
func hex(_ d: Data) -> String { d.isEmpty ? "<empty>" : d.map { String(format: "%02x", $0) }.joined(separator: " ") }

let seconds = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 180) : 180
let scanOnly = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "scanOnly"

let FC50 = CBUUID(string: "FC50")
let FE95 = CBUUID(string: "FE95")
let AFU_PRODUCT: UInt16 = 0x391F   // 14623

func isCandidate(name: String, adv a: [String: Any]) -> String? {
    if let sd = a[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
        if let v = sd[FC50] {
            if v.count == 11, v[0] == 0xAF, v[1] == 0x01 {
                return "AFU-FC50-ADV"
            }
            return "FC50-odd(\(v.count)B)"
        }
        if let v = sd[FE95], v.count >= 4 {
            let pid = (UInt16(v[2]) << 8) | UInt16(v[3])
            if pid == AFU_PRODUCT { return "FE95-product-0x391F" }
        }
    }
    let n = name.lowercased()
    for k in ["afu", "scale", "体脂", "秤", "weight"] where n.contains(k) { return "name:\(name)" }
    return nil
}

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!
    var seen: Set<UUID> = []
    var connected: Set<UUID> = []
    var knownProps: [UUID: [String: CBCharacteristicProperties]] = [:]
    var svcSeen: [UUID: Set<String>] = [:]

    func start() { c = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ m: CBCentralManager) {
        guard m.state == .poweredOn else {
            emit("# state=\(m.state.rawValue)")
            if m.state == .unauthorized { exit(2) }
            return
        }
        emit("# afuprobe: scan \(Int(seconds))s, scanOnly=\(scanOnly), watching FC50 / FE95 product 0x391F / scale names")
        m.scanForPeripherals(withServices: nil,
                             options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            emit("# timeout, candidates=\(self.connected.count), devices=\(self.seen.count)")
            exit(0)
        }
    }

    func centralManager(_ m: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData a: [String: Any], rssi r: NSNumber) {
        let name = (a[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        var parts: [String] = []
        if let sd = a[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (k, v) in sd.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                parts.append("sdata(\(k.uuidString))=\(hex(v))")
            }
        }
        if let uuids = a[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            parts.append("svc=[\(uuids.map { $0.uuidString }.joined(separator: ","))]")
        }
        if let md = a[CBAdvertisementDataManufacturerDataKey] as? Data { parts.append("mfr=\(hex(md))") }
        let tag = isCandidate(name: name, adv: a)
        if let t = tag { parts.append("<<< \(t)") }
        let body = "\(name.isEmpty ? "<noname>" : name) rssi=\(r.intValue) id=\(p.identifier.uuidString) " + parts.joined(separator: " | ")
        // log every packet for an already-flagged device, plus first sighting of anything
        if tag != nil || !seen.contains(p.identifier) {
            seen.insert(p.identifier)
            emit(body)
        }
        guard tag != nil, !scanOnly, !connected.contains(p.identifier) else { return }
        connected.insert(p.identifier)
        emit("### CONNECT \(body)")
        p.delegate = self
        c.connect(p, options: nil)
    }

    func centralManager(_ m: CBCentralManager, didConnect p: CBPeripheral) {
        emit("### connected \(p.name ?? "?") \(p.identifier.uuidString) — discovering services")
        p.discoverServices(nil)
    }

    func centralManager(_ m: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        emit("### connect failed \(p.identifier.uuidString): \(error?.localizedDescription ?? "?")")
    }

    func centralManager(_ m: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        emit("### disconnected \(p.identifier.uuidString) \(error?.localizedDescription ?? "clean")")
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error { emit("### services error: \(e.localizedDescription)"); return }
        for s in p.services ?? [] {
            emit("### SVC \(s.uuid.uuidString)")
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        if let e = error { emit("### chars error: \(e.localizedDescription)"); return }
        for c in s.characteristics ?? [] {
            var props: [String] = []
            if c.properties.contains(.read) { props.append("r") }
            if c.properties.contains(.write) { props.append("w") }
            if c.properties.contains(.writeWithoutResponse) { props.append("wn") }
            if c.properties.contains(.notify) { props.append("n") }
            if c.properties.contains(.indicate) { props.append("i") }
            emit("###   CH \(c.uuid.uuidString) [\(props.joined())] (svc \(s.uuid.uuidString))")
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                p.setNotifyValue(true, for: c)
            }
            if c.properties.contains(.read) {
                p.readValue(for: c)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let e = error { emit("### read/notify error \(c.uuid.uuidString): \(e.localizedDescription)"); return }
        emit("### VALUE \(c.uuid.uuidString) (\(c.value?.count ?? 0)B) = \(hex(c.value ?? Data()))")
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        emit("### notify \(c.isNotifying ? "ON" : "OFF") \(c.uuid.uuidString) err=\(error?.localizedDescription ?? "-")")
    }
}

let probe = Probe(); probe.start(); RunLoop.main.run()
