import Cocoa
import CoreBluetooth

// blegatt: connect to a BLE peripheral by name substring (or identifier), dump its
// GATT tree, subscribe to everything notifiable, and print every notification as
// hex with millisecond timestamps. This is the reverse-engineering workhorse.
//
// usage: blegatt <name-substring|id> [connectSeconds]
// env:   BLE_OUT=/tmp/blegatt.out

let outPath = ProcessInfo.processInfo.environment["BLE_OUT"] ?? "/tmp/blegatt.out"
FileManager.default.createFile(atPath: outPath, contents: nil)
let outFile = FileHandle(forWritingAtPath: outPath)

let stamp = { () -> String in
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

func emit(_ s: String) {
    let line = "[\(stamp())] \(s)"
    print(line)
    fflush(stdout)
    outFile?.seekToEndOfFile()
    outFile?.write((line + "\n").data(using: .utf8)!)
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined(separator: " ")
}

let target = (CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "").lowercased()
let connectSeconds = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 120.0) : 120.0
if target.isEmpty {
    emit("usage: blegatt <name-substring|uuid> [seconds]")
    exit(1)
}

final class Gatt: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var known: Set<UUID> = []

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            emit("# central state=\(c.state.rawValue)")
            if c.state == .unauthorized { exit(2) }
            return
        }
        emit("# scanning for '\(target)'")
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + connectSeconds) {
            emit("# timeout, stopping")
            exit(0)
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData adv: [String: Any], rssi rssi: NSNumber) {
        let name = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let idMatch = p.identifier.uuidString.lowercased().hasPrefix(target)
        guard name.lowercased().contains(target) || idMatch else { return }
        if !known.contains(p.identifier) {
            known.insert(p.identifier)
            var line = "# FOUND '\(name)' id=\(p.identifier.uuidString) rssi=\(rssi)"
            if let sd = adv[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
                for (k, v) in sd.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                    line += " | sdata(\(k.uuidString))=\(hex(v))"
                }
            }
            if let md = adv[CBAdvertisementDataManufacturerDataKey] as? Data { line += " | mfr=\(hex(md))" }
            emit(line)
        }
        // only connect to the best (first) match and only once
        if peripheral == nil {
            peripheral = p
            p.delegate = self
            c.stopScan()
            emit("# connecting to \(name.isEmpty ? p.identifier.uuidString : name) ...")
            c.connect(p, options: nil)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        emit("# connected")
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        emit("# connect failed: \(error?.localizedDescription ?? "?")")
        exit(5)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        emit("# disconnected: \(error?.localizedDescription ?? "ok")")
        exit(0)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error { emit("# discoverServices error: \(e.localizedDescription)"); return }
        for s in p.services ?? [] {
            emit("# SERVICE \(s.uuid.uuidString) \(s.characteristics?.count ?? -1) chars")
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        if let e = error { emit("# discoverChars error: \(e.localizedDescription)"); return }
        for ch in s.characteristics ?? [] {
            var props: [String] = []
            if ch.properties.contains(.read) { props.append("read") }
            if ch.properties.contains(.write) { props.append("write") }
            if ch.properties.contains(.writeWithoutResponse) { props.append("writeNR") }
            if ch.properties.contains(.notify) { props.append("notify") }
            if ch.properties.contains(.indicate) { props.append("indicate") }
            if ch.properties.contains(.broadcast) { props.append("broadcast") }
            emit("  CHAR \(ch.uuid.uuidString) [\(props.joined(separator: ","))]")
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                p.setNotifyValue(true, for: ch)
                emit("    -> subscribed")
            }
            if ch.properties.contains(.read) {
                p.readValue(for: ch)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { emit("# read/notify error \(ch.uuid.uuidString): \(e.localizedDescription)"); return }
        emit("DATA \(ch.uuid.uuidString) len=\(ch.value?.count ?? 0) : \(hex(ch.value ?? Data()))")
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        emit("# wrote \(ch.uuid.uuidString) \(error == nil ? "ok" : "err: \(error!.localizedDescription)")")
    }
}

let gatt = Gatt()
gatt.start()
RunLoop.main.run()
