// afuscale.swift - attach to the AFU x Welland body-fat scale (icomon FFB0 protocol)
// Reversed from com.antgroup.aijk.android (icomon ICWeightScale27Worker + ICBleScale27Protocol)
// Usage: open -n ./AFUScale.app --args [seconds] [connect-only|with-writes]
import Foundation
import CoreBluetooth

let outPath = ProcessInfo.processInfo.environment["BLE_OUT"] ?? "/tmp/afuscale.out"
let args = CommandLine.arguments
let seconds = args.count > 1 ? (Double(args[1]) ?? 300) : 300
let mode = args.count > 2 ? args[2] : "connect-only"
let doWrites = mode == "with-writes" || mode == "fix"
let doFix = mode == "fix"

// ---- profile: supplied at runtime, never hard-coded ----------------
//   AFU_H=175 AFU_AGE=42 AFU_SEX=1 AFU_WEIGHT=78.40 AFU_TARGET=78.40 AFU_K=0.9788
// default = placeholder demo values (175 cm / 42 y / male / 78.40 kg)
let ENV = ProcessInfo.processInfo.environment
func envI(_ k: String, _ d: Int) -> Int { Int(ENV[k] ?? "") ?? d }
func envD(_ k: String, _ d: Double) -> Double { Double(ENV[k] ?? "") ?? d }
let U_HEIGHT = envI("AFU_H", 175), U_AGE = envI("AFU_AGE", 42), U_SEX = envI("AFU_SEX", 1)
let U_UNIT = 0 /* kg */
let U_INDEX = 1, U_PEOPLE = 0 /* 0=normal, 1=sportman */, U_VER = 1 /* protocol_ver from adv byte[8] */
let U_WEIGHT = envD("AFU_WEIGHT", 78.40), U_TARGET = envD("AFU_TARGET", U_WEIGHT)

let logURL = URL(fileURLWithPath: outPath)
FileManager.default.createFile(atPath: outPath, contents: nil)
let fh = try! FileHandle(forWritingTo: logURL)
let startAt = Date()
let df: DateFormatter = { let d = DateFormatter(); d.dateFormat = "HH:mm:ss.SSS"; return d }()

func log(_ s: String) {
    let line = "[\(df.string(from: Date()))] \(s)\n"
    if let d = line.data(using: .utf8) { fh.write(d) }
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
}
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

let SVC_FFB0 = CBUUID(string: "0000FFB0-0000-1000-8000-00805F9B34FB")
let CH_FFB1 = CBUUID(string: "0000FFB1-0000-1000-8000-00805F9B34FB")   // write (no response)
let CH_FFB2 = CBUUID(string: "0000FFB2-0000-1000-8000-00805F9B34FB")   // notify
let SVC_DIS = CBUUID(string: "0000180A-0000-1000-8000-00805F9B34FB")
// AFU_UUID = the scale's CoreBluetooth identifier, e.g. from a scan. Placeholder default.
let KNOWN = UUID(uuidString: ENV["AFU_UUID"] ?? "11111111-2222-3333-4444-555555555555")!

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var target: CBPeripheral?
    var seen: Set<UUID> = []
    var notifying: [CBCharacteristic] = []
    var writeChar: CBCharacteristic?
    var pending = 0
    var frames = 0
    var lastLog: [UUID: String] = [:]
    var lastAttempt = Date()
    var advCount = 0

    func start() {
        log("=== afuscale start, \(Int(seconds))s, writes=\(doWrites), out=\(outPath)")
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("central state=\(central.state.rawValue)")
        guard central.state == .poweredOn else { return }
        if let p = central.retrievePeripherals(withIdentifiers: [KNOWN]).first {
            log("### cached peripheral: \(p.name ?? "?") id=\(p.identifier)")
            attach(p)
        } else { log("### known UUID not retrievable yet") }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func attach(_ p: CBPeripheral) {
        if target != nil { return }
        target = p
        lastAttempt = Date()
        p.delegate = self
        log("### CONNECT \(p.name ?? "?") id=\(p.identifier)")
        central.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData adv: [String: Any], rssi RSSI: NSNumber) {
        let name = adv[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? ""
        var sds: [String] = []
        if let sl = adv[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (u, d) in sl { sds.append("sdata(\(u.uuidString.prefix(4)))=\(hex([UInt8](d)))") }
        }
        let svc = (adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map { $0.uuidString.prefix(4) }.joined(separator: ",")
        let mfr = (adv[CBAdvertisementDataManufacturerDataKey] as? Data).map { hex([UInt8]($0)) } ?? ""
        let line = "\(name) rssi=\(RSSI) \(sds.joined(separator: " ")) | svc=[\(svc)] mfr=\(mfr)"
        let key = p.identifier
        if lastLog[key] != line {
            lastLog[key] = line
            if name.contains("AFU") || p.identifier == KNOWN || line.contains("FFB0") || line.contains("27AC") {
                advCount += 1
                log("adv \(line) id=\(p.identifier)")
            }
        }
        let interesting = name.uppercased().contains("AFU-WL") || p.identifier == KNOWN
        if interesting && target == nil {
            attach(p)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("### connected \(p.name ?? "?") -> discoverServices")
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("### didFailToConnect \(p.name ?? "?") err=\(String(describing: error))")
        if target?.identifier == p.identifier { target = nil }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("### disconnected \(p.name ?? "?") err=\(String(describing: error))")
        if target?.identifier == p.identifier { target = nil }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error { log("!!! discoverServices err=\(e)") }
        for s in p.services ?? [] {
            log("### SVC \(s.uuid.uuidString)")
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        if let e = error { log("!!! discoverChars \(s.uuid) err=\(e)") }
        for ch in s.characteristics ?? [] {
            let props = ch.properties
            var ps: [String] = []
            if props.contains(.read) { ps.append("r") }
            if props.contains(.write) { ps.append("w") }
            if props.contains(.writeWithoutResponse) { ps.append("wn") }
            if props.contains(.notify) { ps.append("n") }
            if props.contains(.indicate) { ps.append("i") }
            log("### CH \(s.uuid.uuidString.prefix(4))/\(ch.uuid.uuidString) [\(ps.joined(separator: ""))]")
            if ch.uuid == CH_FFB1 { writeChar = ch }
            if props.contains(.notify) || props.contains(.indicate) {
                if ch.uuid == CH_FFB2 || s.uuid == SVC_FFB0 {
                    p.setNotifyValue(true, for: ch)
                    notifying.append(ch)
                    log("--> setNotify \(ch.uuid.uuidString)")
                }
            }
            if props.contains(.read) && s.uuid == SVC_DIS {
                p.readValue(for: ch)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        log("### notify \(ch.uuid.uuidString) enabled=\(ch.isNotifying) err=\(String(describing: error))")
        if ch.isNotifying && ch.uuid == CH_FFB2 && doWrites {
            sendTimeFrame(p)
            if doFix {
                // let the scale settle on the time frame before pushing user profile
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self = self, let pp = self.target else { return }
                    self.sendHistoryAck(pp)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard let pp2 = self.target else { return }
                        self.sendUserInfoFrame(pp2)
                    }
                }
            }
        }
    }

    // checksum helper: sum(frame[2...lastPayload]) & 0xFF, appended as the 20th byte
    func seal(_ body: [UInt8]) -> [UInt8] {
        var f = body
        var sum: UInt8 = 0
        for i in 2..<f.count { sum = sum &+ f[i] }
        f.append(sum)
        return f
    }

    func write(_ p: CBPeripheral, _ f: [UInt8], _ label: String) {
        guard let wc = writeChar else { log("!! no write char"); return }
        log("--> WRITE \(label) \(hex(f))")
        p.writeValue(Data(f), for: wc, type: .withoutResponse)
    }

    // icomon ICBleScale27Protocol.encodeSetting(operate_type=4, reply_cmd=216): clears the pending history record
    func sendHistoryAck(_ p: CBPeripheral) {
        var f: [UInt8] = [0xAC, 0x27, 0x04, 0xD8]
        f += [UInt8](repeating: 0, count: 14)
        f.append(0xDF)
        write(p, seal(f), "history-ack(216)")
    }

    // icomon ICBleScale27Protocol.encodeTimeAndUserInfo(encode(1)) — this is what AFU writes on connect
    func sendUserInfoFrame(_ p: CBPeripheral) {
        var f: [UInt8] = [0xAC, 0x27]
        let t = UInt32(Date().timeIntervalSince1970)
        f += [UInt8(t & 0xFF), UInt8((t >> 8) & 0xFF), UInt8((t >> 16) & 0xFF), UInt8((t >> 24) & 0xFF)]
        f.append(UInt8(truncatingIfNeeded: Int(TimeZone.current.secondsFromGMT()) / 900))
        f.append(UInt8(U_UNIT))
        f.append(UInt8(U_INDEX))
        f.append(UInt8(U_HEIGHT))
        let w = UInt16(min(65535, Int((U_WEIGHT * 100).rounded())))
        f.append(UInt8(w & 0xFF)); f.append(UInt8((w >> 8) & 0xFF))
        f.append(UInt8(U_AGE))
        f.append(UInt8(U_SEX))
        let tw = UInt16(min(65535, Int((U_TARGET * 100).rounded())))
        f.append(UInt8(tw & 0xFF)); f.append(UInt8((tw >> 8) & 0xFF))
        // flags: bit0 = fun_open_imp, bit1 = littleweight, bit4 = baby_mode
        f.append(0x01)
        f.append(0x00)
        f.append(0xD0)
        write(p, seal(f), "userinfo(imp=1 h=\(U_HEIGHT) age=\(U_AGE) sex=\(U_SEX) w=\(U_WEIGHT))")
    }

    // icomon ICBleScale27Protocol.encodeSetting(operate_type=8): AC <type> 08 <time int32 LE> <utc/900> 00*10 <0xDF> <checksum>
    func sendTimeFrame(_ p: CBPeripheral) {
        guard let wc = writeChar else { log("!! no write char"); return }
        var f: [UInt8] = [0xAC, 0x27, 0x08]
        let t = UInt32(Date().timeIntervalSince1970)
        f += [UInt8(t & 0xFF), UInt8((t >> 8) & 0xFF), UInt8((t >> 16) & 0xFF), UInt8((t >> 24) & 0xFF)]
        let utc = Int(TimeZone.current.secondsFromGMT()) / 900
        f.append(UInt8(truncatingIfNeeded: utc))
        f += [UInt8](repeating: 0, count: 10)
        f.append(0xDF)
        write(p, seal(f), "time-frame")
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { log("!!! didUpdateValue \(ch.uuid) err=\(e)") }
        guard let d = ch.value else { return }
        let b = [UInt8](d)
        frames += 1
        log("<-- \(ch.uuid.uuidString.prefix(4)) len=\(b.count) \(hex(b))")
        decodeAFU(b)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        log("### didWrite \(ch.uuid.uuidString.prefix(4)) err=\(String(describing: error))")
    }

    // MARK: - icomon ICBleScale27Protocol decoders
    // frame: [0]=0xAC [1]=deviceType [2..17]=payload [18]=command [19]=checksum(sum([2..18]) & 0x1F)
    // command: 0xD5 weight, 0xD6 adc/impedance, 0xD8 history, 0xDF setting

    @inline(__always) func u16(_ a: [UInt8], _ o: Int) -> Int {
        guard o + 1 < a.count else { return 0 }
        return (Int(a[o]) << 8) | Int(a[o + 1])
    }
    @inline(__always) func u32(_ a: [UInt8], _ o: Int) -> UInt32 {
        guard o + 3 < a.count else { return 0 }
        return (UInt32(a[o]) << 24) | (UInt32(a[o + 1]) << 16) | (UInt32(a[o + 2]) << 8) | UInt32(a[o + 3])
    }

    // ICCommon.g2kg_general(weight_g, kg_division, precision)
    func g2kg(_ g: Double, _ div: Int) -> Double {
        let ms = Int(g)  // weight_g already integer
        switch div {
        case 0: return Double((ms + 5) / 10) / 100.0
        case 1:
            var x = ms
            if x % 10 == 9 { x += 10 }
            var v = x / 10
            if v % 2 == 1 { v += 1 }
            return Double(v) / 100.0
        case 2:
            let i6 = (ms + 20) / 10
            return Double(i6 % 10 >= 5 ? (i6 / 10) * 10 + 5 : (i6 / 10) * 10) / 100.0
        case 3: return Double((ms + 5) / 10) / 10.0
        default: return g / 1000.0
        }
    }

    // split a 4-byte core into weight + flags
    func coreInfo(_ core: UInt32) -> String {
        let wg = Int(core & 0x3FFFF)
        let kgDiv = Int((core & 0x1C0000) >> 18)
        let lbDiv = Int((core & 0xE00000) >> 21)
        let state = (core >> 31) & 1
        let dianji = (core >> 24) & 1
        let hr = (core >> 25) & 1
        let ph = (core >> 26) & 1
        let zx = (core >> 27) & 1
        let temp = (core >> 28) & 1
        let kg = g2kg(Double(wg), kgDiv)
        return "weight_g=\(wg) weight=\(String(format: "%.2f", kg))kg kgDiv=\(kgDiv) lbDiv=\(lbDiv) state=\(state) dianji=\(dianji) hr=\(hr) ph=\(ph) zx=\(zx) temp=\(temp)"
    }

    // ---- body composition model, calibrated 2026-11-05 against AFU official output ----
    // FFM = K * H^2 / Zavg ; all 12 metrics are linear in FFM (verified vs 22:57 official)
    let BODY_H_CM = envD("AFU_H", 175)
    let BODY_K = envD("AFU_K", 0.9788)
    func bodyComp(_ weightKg: Double, _ imps: [Double]) -> String? {
        let valid = imps.filter { $0 > 0 }
        guard !valid.isEmpty, weightKg > 1 else { return nil }
        let zavg = valid.reduce(0, +) / Double(valid.count)
        let h2 = BODY_H_CM * BODY_H_CM
        let ffm = BODY_K * h2 / zavg
        let fatKg = weightKg - ffm
        guard fatKg > 0 else { return nil }
        let fatPct = fatKg / weightKg * 100
        let waterKg = 0.63183 * ffm, protKg = 0.31068 * ffm
        let musKg = 0.95090 * ffm, skelKg = 0.43868 * ffm
        let bmr = 370.0 + 21.6 * ffm
        let bmi = weightKg / ((BODY_H_CM / 100.0) * (BODY_H_CM / 100.0))
        let f1: (Double) -> String = { String(format: "%.1f", $0) }
        return "BODY fat=\(f1(fatPct))% fatKg=\(f1(fatKg)) FFM=\(f1(ffm)) water=\(f1(waterKg))kg(\(f1(waterKg / weightKg * 100))%) protein=\(f1(protKg))kg(\(f1(protKg / weightKg * 100))%) muscle=\(f1(musKg))kg(\(f1(musKg / weightKg * 100))%) skelMuscle=\(f1(skelKg))kg(\(f1(skelKg / weightKg * 100))%) BMR=\(Int(bmr.rounded()))kcal BMI=\(f1(bmi)) Zavg=\(f1(zavg))"
    }

    func decodeAFU(_ b: [UInt8]) {
        guard b.count >= 8, b[0] == 0xAC else { log("    (not a 27-protocol frame)"); return }
        let devType = b[1]
        let cmd = b[b.count - 2]
        let unit = Int((b[b.count - 1] & 0xE0) >> 5)
        var s: UInt16 = 0
        for i in 2..<(b.count - 1) { s = s &+ UInt16(b[i]) }
        let ck = UInt8(s & 0x1F) == (b[b.count - 1] & 0x1F) ? "ok" : "BAD"
        let p = Array(b[2..<(b.count - 2)])   // payload; p[i] == frame[2+i]
        let uName = [0: "kg", 1: "lb", 2: "st", 3: "jin"]
        switch cmd {
        case 0xD5:  // weight
            let core = u32(p, 0)
            let mode = p[4]
            var extra = ""
            if mode == 1 {
                extra = "calibMode=\(p[5]) battery=\(p[6] & 127)% charging=\((p[6] >> 7) & 1) overWeight=\(p[7])"
            } else if mode == 2 {
                let funs = u32(p, 5)
                var on: [String] = []
                for bit in 0..<32 where (funs >> UInt32(bit)) & 1 == 1 { on.append("bit\(bit)") }
                let bb = p[9]
                extra = "battery=\(bb == 0 ? 255 : bb & 127)% charging=\((bb >> 7) & 1) supportFuns=[\(on.joined(separator: ","))]"
            } else {
                extra = "mode=\(mode) raw=[\(hex(Array(p[4...]))) ]"
            }
            log("    [WEIGHT] ck=\(ck) dev=0x\(String(format: "%02X", devType)) \(coreInfo(core)) \(extra) alg=\(p[15]) unit=\(unit)(\(uName[unit] ?? "?"))")
        case 0xD6:  // adc / impedance
            let n = Int(p[0])
            var adcs: [Int] = []
            for k in 0..<n where 2 + 2 * k + 1 < p.count { adcs.append(u16(p, 2 + 2 * k)) }
            let mode = (3 + 2 * n < p.count) ? p[2 + 2 * n] : 0
            var core: UInt32 = 0
            if mode == 1 { core = u32(p, 3 + 2 * n) }
            var impInfo = ""
            if !adcs.isEmpty, core != 0 {
                let kg = g2kg(Double(Int(core & 0x3FFFF)), Int((core & 0x1C0000) >> 18))
                var imps: [Double] = []
                for a in adcs {
                    var v = Double(a)
                    if v >= 1500 { v = ((v - 1000.0) + (kg * 10.0 * -0.4)) / 0.6 / 10.0 }
                    imps.append(v)
                }
                impInfo = "imp=[\(imps.map { String(format: "%.1f", $0) }.joined(separator: ", "))]Ω"
            }
            let coreStr = core != 0 ? coreInfo(core) : "(no weight in frame)"
            log("    [ADC] ck=\(ck) n=\(n) adcs=\(adcs) mode=\(mode) \(coreStr) \(impInfo) alg=\(p.count > 15 ? p[15] : 0) unit=\(unit)(\(uName[unit] ?? "?"))")
            if !adcs.isEmpty, core != 0 {
                let kg = g2kg(Double(Int(core & 0x3FFFF)), Int((core & 0x1C0000) >> 18))
                var imps: [Double] = []
                for a in adcs {
                    var v = Double(a)
                    if v >= 1500 { v = ((v - 1000.0) + (kg * 10.0 * -0.4)) / 0.6 / 10.0 }
                    imps.append(v)
                }
                if let bc = bodyComp(kg, imps) { log("    \(bc)") }
            }
        case 0xD8:  // history record
            let kind = Int(p[0])
            let ts = Int(u32(p, 1))
            let core = u32(p, 5)
            let tstr = Date(timeIntervalSince1970: TimeInterval(ts)).description(with: Locale.current)
            var pos = 9
            var adcs: [Int] = []
            var hr = 0, hcount = 0
            if kind == 0 {
                pos += 2                             // ReadShort (unused)
                if pos < p.count { hr = Int(p[pos]); pos += 1 }
                if pos < p.count { let c = Int(p[pos]); pos += 1
                    for _ in 0..<c where pos + 1 < p.count { adcs.append(u16(p, pos)); pos += 2 } }
            } else if kind == 2 {
                if pos < p.count { hcount = Int(p[pos]); pos += 1 }
                if pos < p.count { let c = Int(p[pos]); pos += 1
                    for _ in 0..<c where pos + 1 < p.count { adcs.append(u16(p, pos)); pos += 2 } }
            } else {
                for _ in 0..<2 where pos + 1 < p.count { adcs.append(u16(p, pos)); pos += 2 }
                pos += 2
            }
            let alg = pos < p.count ? Int(p[pos]) : 0
            let un = pos + 1 < p.count ? Int(p[pos + 1]) : unit
            log("    [HISTORY] ck=\(ck) kind=\(kind) time=\(ts)(\(tstr)) \(coreInfo(core)) hr=\(hr) remain=\(hcount) adcs=\(adcs) alg=\(alg) unit=\(un)")
        case 0xDF:
            log("    [SETTING] ck=\(ck) payload=[\(hex(p))]")
        default:
            log("    [cmd 0x\(String(format: "%02X", cmd))] ck=\(ck) payload=[\(hex(p))]")
        }
    }
}

let probe = Probe()
probe.start()
let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    if let t = probe.target {
        if t.state == .disconnected { probe.target = nil }
        else if t.state == .connecting && Date().timeIntervalSince(probe.lastAttempt) > 10 {
            log("### connect timeout on \(t.name ?? "?"), retrying")
            probe.central.cancelPeripheralConnection(t)
            probe.target = nil
        }
    } else if Date().timeIntervalSince(probe.lastAttempt) > 8,
              let p = probe.central.retrievePeripherals(withIdentifiers: [KNOWN]).first,
              probe.advCount > 0 || Date().timeIntervalSince(startAt) > 20 {
        probe.attach(p)
    }
}
log("=== done, frames=\(probe.frames), elapsed=\(Int(Date().timeIntervalSince(startAt)))s")
try? fh.close()
exit(0)
