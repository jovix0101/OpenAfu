import Cocoa
import CoreBluetooth

// advlog: pure advertisement logger. Never connects. Logs EVERY advertisement of
// the target device (duplicates allowed) with a millisecond timestamp, so short
// measurement bursts (e.g. a MiBeacon weight frame) are not missed.
//
// usage: advlog <name-substring|all> <seconds>
// env: BLE_OUT (default /tmp/advlog.out)

let outPath = ProcessInfo.processInfo.environment["BLE_OUT"] ?? "/tmp/advlog.out"
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

final class L: NSObject, CBCentralManagerDelegate {
    var c: CBCentralManager!
    func start() { c = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ m: CBCentralManager) {
        guard m.state == .poweredOn else {
            emit("# state=\(m.state.rawValue)")
            if m.state == .unauthorized { exit(2) }
            return
        }
        emit("# passive scan '\(target)' for \(Int(seconds))s (no connect)")
        m.scanForPeripherals(withServices: nil,
                             options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { emit("# timeout"); exit(0) }
    }

    func centralManager(_ m: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData a: [String: Any], rssi r: NSNumber) {
        let name = (a[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard target == "all" || name.lowercased().contains(target) else { return }
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
        emit("\(name) rssi=\(r.intValue) " + parts.joined(separator: " | "))
    }
}

let l = L(); l.start(); RunLoop.main.run()
