# 探测工具（脱敏版）

这些是调研期间写的**一次性探针**，不是产品代码。产品化实现在独立仓库 [`jovix0101/scalebar`](https://github.com/jovix0101/scalebar)。

与根目录那些早期脚本的区别：这里的版本**不含任何真实设备 UUID / 个人资料**。`afuscale.swift` 的所有人设与设备标识都从环境变量读，默认值是合成演示值（175 cm / 42 岁 / 男 / 78.40 kg / 占位 UUID）。

## 通用构建与运行

macOS 上 CoreBluetooth 要求：可执行文件必须在一个带 `NSBluetoothAlwaysUsageDescription` 的 `.app` bundle 里、ad-hoc 签名、并且用 `open -n` 启动。`open` 会丢掉 stdout，所以每个工具都把日志写到文件（环境变量 `BLE_OUT`）。

```bash
# 1) 做一个宿主 bundle（只需一次）
mkdir -p BLEBridge.app/Contents/MacOS
cat > BLEBridge.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>blescan</string>
  <key>CFBundleIdentifier</key><string>dev.openafu.blebridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>读取体重秤广播与数据。</string>
  <key>NSBluetoothPeripheralUsageDescription</key><string>读取体重秤广播与数据。</string>
</dict></plist>
PLIST

# 2) 编译某个工具，塞进宿主（每次换二进制都要重签）
swiftc -O blescan.swift -o BLEBridge.app/Contents/MacOS/blescan
codesign --force --deep --sign - BLEBridge.app
open -n ./BLEBridge.app --args 30
tail -f /tmp/blescan.out
```

> 把 `CFBundleExecutable` 换成对应二进制名，或统一用一个名字（例如都输出成 `afuprobe`），重签即可。
> Swift delegate 的方法签名必须用 `error:` 外部标签（`didDiscoverServices error:` 等），写成 `e:` 只会有 warning 但**回调永不触发** —— 这几个文件里都是修正后的写法。

## 工具一览

| 文件 | 作用 | 参数 | 默认输出 |
| --- | --- | --- | --- |
| `blescan.swift` | 扫一圈，打印每台设备的 `name / id / rssi / svc / sdata(UUID)=hex / mfr=hex` | 秒数 | `/tmp/blescan.out` |
| `advlog.swift` | **被动**高频扫描（`AllowDuplicatesKey`），只在广播载荷变化时打一行，带毫秒时间戳，**从不连接** | `"Mijia Scale"` 之类的名字子串或 `all`、秒数 | `/tmp/advlog.out` |
| `blegatt.swift` | 按名字连接 → 枚举整棵 GATT → 给所有 notify 特征订阅，打印每帧 hex | 名字子串、秒数 | `/tmp/blegatt.out` |
| `scalewatch.swift` | 同时做「广播变化」+「连接订阅」两件事 | 名字子串、秒数 | `/tmp/scalewatch.out` |
| `afuprobe.swift` | 扫全量广播，命中 `AFU-WL*` / FC50 service data / 指定 FE95 productId 才连接并订阅 | 秒数、`scanOnly` 可选 | `/tmp/afuprobe.out` |
| `afuscale.swift` | **完整参考实现**：连接 → 读设备信息 → 订阅 `FFB2` → 写时间 / 用户信息 / 历史确认帧 → 解 `0xD5/0xD6/0xD8/0xDF` → 算全套体成分 | 秒数、`connect-only` / `with-writes` / `fix` | `/tmp/afuscale.out` |
| `scan.py` | bleak 版扫描。在 macOS 上会因 Info.plist 缺 usage string 直接 SIGABRT —— **留作反面教材**，别用来干活 | — | stdout |

## `afuscale.swift` 的环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `AFU_UUID` | `11111111-2222-3333-4444-555555555555` | 已知设备的 CoreBluetooth identifier；留空则先扫描按名字匹配 |
| `AFU_H` | `175` | 身高 cm |
| `AFU_AGE` | `42` | 年龄 |
| `AFU_SEX` | `1` | 1 男 / 2 女 |
| `AFU_WEIGHT` | `78.40` | 用户信息帧里的当前体重 kg |
| `AFU_TARGET` | 同 `AFU_WEIGHT` | 目标体重 kg |
| `AFU_K` | `0.9788` | 体成分模型标定系数，见 `docs/04-body-model.md` |
| `BLE_OUT` | `/tmp/afuscale.out` | 日志路径 |

三种模式：

```bash
open -n ./BLEBridge.app --args 1800 connect-only   # 只连 + 看通知（不写帧，通常什么也收不到）
open -n ./BLEBridge.app --args 1800 with-writes    # 写时间帧，能拿到体重 / 阻抗 / 历史
open -n ./BLEBridge.app --args 1800 fix            # 额外写用户信息帧（imp=1）与历史 ACK
```

`fix` 用来修「只报体重、阻抗恒为 0」的状态，见 `docs/02-protocol.md` §8。

## 用完记得释放 BLE

```bash
pkill -f "BLEBridge.app/Contents/MacOS/"
```

BLE 是点对点的，工具占着连接时手机 App 收不到数据。测完立刻断开，让 App 正常工作。

## 与 ScaleBar 的关系

`afuscale.swift` 是协议的**可执行规格说明**：帧格式、校验和、端序、阻抗换算、体成分公式都能在这里直接读到。ScaleBar 把这些逻辑抽成了 `ScaleBarCore`（`Frames.swift` / `Metrics.swift` / `Units.swift`），加上 SQLite 存储、菜单栏 UI、单元测试和 CI。想改协议先在这里验证，再搬过去。

## 别把真实数据写回仓库

调试时抓到的帧含真实体重与阻抗。要写文档 / 测试，请用 `samples/decode.py` 造合成帧，参考 `docs/07-privacy.md`。
