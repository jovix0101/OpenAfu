import Cocoa
import CoreBluetooth

// scalewatch: simultaneously (a) scan advertisements from the target device and
// print its FE95 service-data frames, and (b) connect and subscribe to every
// notify characteristic, printing notifications. Use while stepping on the scale.
//
// usage: scalewatch <name-substring> [seconds]
// env: BLE_OUT

let outPath = ProcessInfo.processInfo.environment["BLE_OUT"] ?? "/tmp/scalewatch.out"
FileManager.default.createFile(atPath: outPath, contents: nil)
let outFile = FileHandle(forWritingAtPath: outPath)
let df = DateFormatter(); df.dateFormat = "HH:mm:ss.SSS"
func emit(_ s: String) {
    let line = "[\(df.string(from: Date()))] \(s)"
    print(line); fflush(stdout)
    outFile?.seekToEndOfFile(); outFile?.write((line + "\n").data(using: .utf8)!)
}
func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined(separator: " ") }

let target = (CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "mijia").lowercased()
let seconds = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 300) : 300

final class W: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var c: CBCentralManager!
    var p: CBPeripheral?
    var connected = false
    var lastAdv: String = ""

    func start() { c = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ m: CBCentralManager) {
        guard m.state == .poweredOn else {
            emit("# state=\(m.state.rawValue)"); if m.state == .unauthorized { exit(2) }; return
        }
        emit("# scan+watch '\(target)' for \(Int(seconds))s")
        m.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { emit("# timeout"); exit(0) }
    }

    func centralManager(_ m: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData a: [String: Any], rssi r: NSNumber) {
        let name = (a[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard name.lowercased().contains(target) else { return }
        var parts: [String] = []
        if let sd = a[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (k, v) in sd.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                parts.append("sdata(\(k.uuidString))=\(hex(v))")
            }
        }
        if let md = a[CBAdvertisementDataManufacturerDataKey] as? Data { parts.append("mfr=\(hex(md))") }
        let line = "ADV rssi=\(r.intValue) " + parts.joined(separator: " | ")
        if line != lastAdv {            // print only when payload changes
            lastAdv = line
            emit(line)
        }
        if !connected {
            connected = true
            self.p = p
            p.delegate = self
            emit("# connecting ...")
            m.connect(p, options: nil)
        }
    }

    func centralManager(_ m: CBCentralManager, didConnect p: CBPeripheral) {
        emit("# connected, discovering")
        p.discoverServices(nil)
    }
    func centralManager(_ m: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        emit("# disconnected \(error?.localizedDescription ?? "")")
        connected = false; self.p = nil
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            emit("# SVC \(s.uuid.uuidString)")
            p.discoverCharacteristics(nil, for: s)
        }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            var props: [String] = []
            if ch.properties.contains(.read) { props.append("r") }
            if ch.properties.contains(.write) { props.append("w") }
            if ch.properties.contains(.writeWithoutResponse) { props.append("wn") }
            if ch.properties.contains(.notify) { props.append("n") }
            if ch.properties.contains(.indicate) { props.append("i") }
            emit("  \(s.uuid.uuidString)/\(ch.uuid.uuidString) [\(props.joined(separator: ""))]")
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                p.setNotifyValue(true, for: ch)
            }
            if ch.properties.contains(.read) { p.readValue(for: ch) }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        emit("DATA \(ch.uuid.uuidString) len=\(ch.value?.count ?? 0) : \(hex(ch.value ?? Data()))")
    }
}

let w = W(); w.start(); RunLoop.main.run()
