import Cocoa
import CoreBluetooth

// Output goes to stdout AND to $BLE_OUT (or /tmp/blescan.out) so it works when
// launched via LaunchServices (`open -n BLEBridge.app`) where stdout is detached.
let outPath = ProcessInfo.processInfo.environment["BLE_OUT"] ?? "/tmp/blescan.out"
let outFile = FileHandle(forWritingAtPath: outPath)
func emit(_ s: String) {
    print(s)
    fflush(stdout)
    if let f = outFile {
        f.seekToEndOfFile()
        f.write((s + "\n").data(using: .utf8)!)
    }
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined(separator: " ")
}

var seen: Set<UUID> = []

final class Scanner: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            emit("# state=poweredOn, scanning")
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .unauthorized:
            emit("# ERROR: bluetooth unauthorized (TCC) - allow BLEBridge in System Settings > Privacy > Bluetooth")
            exit(2)
        case .poweredOff:
            emit("# ERROR: bluetooth powered off")
            exit(3)
        case .unsupported:
            emit("# ERROR: bluetooth unsupported")
            exit(4)
        default:
            emit("# state=\(central.state.rawValue) waiting...")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name ?? "<noname>"
        var line = "\(name) | id=\(peripheral.identifier.uuidString) | rssi=\(RSSI.intValue)"
        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            line += " | svc=[\(uuids.map { $0.uuidString }.joined(separator: ","))]"
        }
        if let sd = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (k, v) in sd.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                line += " | sdata(\(k.uuidString))=\(hex(v))"
            }
        }
        if let md = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            line += " | mfr=\(hex(md))"
        }
        emit(line)
    }
}

let duration = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 10.0) : 10.0
let scanner = Scanner()
DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
    scanner.central.stopScan()
    emit("# done, \(seen.count) unique (dup filter=off)")
    exit(0)
}
RunLoop.main.run()
