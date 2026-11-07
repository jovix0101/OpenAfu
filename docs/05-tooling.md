# 05 · 工具链与踩过的坑

这一章是「下次再做一遍时最省时间的部分」。所有命令都在 macOS（Apple Silicon / macOS 27）+ 一台 Android 手机上验证过。

## 1. adb

```bash
brew install --cask android-platform-tools       # 37.0.1 → /opt/homebrew/bin/adb
adb version                                      # 1.0.41 / 37.0.1-15733141
```

**坑**：机器上原本有个 GUI 工具自带的 `adb`（`AndroMeld.app/Contents/MacOS/adb`），直接跑会 `Trace/BPT trap: 5`（exit 133）。原因是那个二进制带 `com.apple.security.app-sandbox` + `com.apple.security.inherit` entitlements，只能作为宿主 App 的沙盒子进程运行；`arch -x86_64` 也不行（Illegal instruction: 4）。正确做法是装官方 platform-tools，不要去 `cp` + `codesign` 绕过沙盒（那样能用，但没意义）。

```bash
adb devices -l                                   # 无线调试设备 + 同网电视会都列出来
export ANDROID_SERIAL=<手机的 adb 序列号>          # 否则 adb: more than one device/emulator
adb shell monkey -p com.antgroup.aijk.android -c android.intent.category.LAUNCHER 1
adb exec-out screencap -p > /tmp/s.png
adb shell dumpsys bluetooth_manager | grep -A30 "GATT Client Map"
adb bugreport bugreport.zip                     # 63 MB，含系统日志与蓝牙栈文本日志
```

`bugreport` 里最有用的段：`DUMP OF SERVICE bluetooth_manager:` → `GATT Client Map`（AppRecord，含 appName / 起止时间 / `REASON_UNREGISTER_CLIENT`）与 `BluetoothRemoteDevices`（`[Packages]` 归属）。用它确认"是哪个 App 在什么时刻连了 GATT"，比猜强。

**拿不到的东西**：`run-as: package not debuggable`；`/data/misc/bluetooth/logs` 非 root `Permission denied`；`btsnoop_hci.log` 不在 bugreport 里；logcat 环形缓冲只有 256 KiB 且被系统噪声刷满，事后 `-d` 基本捞不到秤的帧（而且 App 的 BLE 日志根本不走 `android.util.Log`）。

## 2. macOS 上用 CoreBluetooth（最大的坑）

### 2.1 Python / bleak 会直接崩

```
SIGABRT — This app has crashed because it attempted to access privacy-sensitive data
without a usage description. The app's Info.plist must contain an
NSBluetoothAlwaysUsageDescription key
```

崩溃报告里的 responsible process 甚至不是 python，而是某个常驻的蓝牙管理 App。给 python 套一层 `.app` 也没用 —— 真正被检查的是**实际可执行文件**（`python3.12`）的宿主 bundle。

### 2.2 可行方案：原生 Swift CLI 编进真正的 `.app`

```bash
swiftc -O blescan.swift -o BLEBridge.app/Contents/MacOS/blescan
```

`BLEBridge.app/Contents/Info.plist` 至少需要：

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>读取体重秤的体重与阻抗数据。</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>读取体重秤的体重与阻抗数据。</string>
```

然后：

```bash
codesign --force --deep --sign - BLEBridge.app     # 每次换二进制都要重签
open -n ./BLEBridge.app --args 30                  # 必须用 open 启动，不能直接跑二进制
```

`open` 启动的进程**stdout 会被丢弃**，所以工具一律把日志写到文件（环境变量 `BLE_OUT`，默认 `/tmp/xxx.out`），再 `tail -f` 看。

**结论**：Info.plist 里两个 usage string 齐全、bundle 结构完整、ad-hoc 签名，再用 `open -n` 启动，CoreBluetooth 回调才会正常触发（`dev.scalebar.app` 就是这么工作的）。

### 2.3 Swift delegate 的静默坑

```swift
// ❌ 编译只给 warning "nearly matches optional requirement"，但回调永不触发
func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) {}

// ✅ 外部标签必须是 error:
func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {}
func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {}
func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {}
```

这个坑表现为"连上了、服务也发现了，但一帧通知都没有"；检查 delegate 方法签名即可定位。

### 2.4 其他

- 扫描要 `CBCentralManagerScanOptionAllowDuplicatesKey: true`，否则同一设备只回调一次，看不到广播内容变化。
- 被动扫描（只看广播、从不 `connect`）与"自动连接并订阅所有 notify"要分成两个工具，别混在一起：连接会抢占手机 App。
- 秤休眠后 `retrievePeripherals(withIdentifiers:)` + `connect` 会一直 10s 超时，需要重试循环 + 显式 deadline。
- 用完 `pkill -f "<bundle>/Contents/MacOS/<bin>"` 主动断开，把 BLE 还给手机 App。

## 3. src/ 里的工具

| 文件 | 用途 | 输出 |
| --- | --- | --- |
| `blescan.swift` | 扫广播，打印 `name / id / rssi / svc / sdata(UUID)=hex / mfr=hex` | `/tmp/blescan.out` |
| `advlog.swift` | 被动高频扫，载荷变化才打一行，带毫秒时间戳；**从不连接** | `/tmp/advlog.out` |
| `blegatt.swift` | 按名字子串连接 → 枚举整棵 GATT → 订阅所有 notify | `/tmp/blegatt.out` |
| `scalewatch.swift` | 同时扫广播变化 + 连接订阅 | `/tmp/scalewatch.out` |
| `afuprobe.swift` | 扫全量广播，命中 `AFU-WL*` 名字或候选 service data 才连接 | `/tmp/afuprobe.out` |
| `afuscale.swift` | **完整参考实现**：连接 + 写时间 / 用户信息 / 历史确认帧 + 解 `0xD5/D6/D8` + 算体成分。个人资料走 `AFU_*` 环境变量 | `/tmp/afuscale.out` |
| `scan.py` | bleak 版扫描，留作"为什么不能这么干"的对照 | stdout |

详见 [`../src/README.md`](../src/README.md)。

## 4. 逆向工具

```bash
# JRE：清华 Adoptium 镜像，约 12 MB/s；GitHub 直连经常超时
# jadx 1.5.6 zip 若下到一半被截断，用 curl -C - 续传
/tmp/jadx_out/bin/jadx -d decomp/afu --no-res --show-bad-code -j 8 apk/afu.apk
```

`strings -a` + `grep` 适合先定位类；`androguard` 适合列类名（注意 `DEX(open(f,'rb').read())`）。全量反编译约 4 分钟，几百个 `ERROR` 可忽略。

## 5. 排查速查表

| 现象 | 先查 |
| --- | --- |
| `Trace/BPT trap: 5` | 用了带沙盒 entitlements 的第三方 adb，换官方 platform-tools |
| CoreBluetooth 一启动就 SIGABRT | Info.plist 缺 `NSBluetoothAlwaysUsageDescription` |
| 连上了但零通知 | delegate 方法标签写成 `e:`；或没 `setCharacteristicNotification(true)`；或没写时间帧 |
| 完全没有广播 | 秤睡着了 —— 让人踩一下唤醒，窗口只有 2～3 分钟 |
| `adb: more than one device/emulator` | `export ANDROID_SERIAL=<手机序列号>` |
| `adb devices` 空 | 无线调试掉了；让手机和电脑在同一 Wi-Fi，重新开「无线调试」并配对 |
| `screencapture -x` 报 `could not create image from display` | 没有屏幕录制权限；改用进程内 `bitmapImageRepForCachingDisplay(in:)` 截图 |
| `open -n` 启动后日志空白 | stdout 被丢弃，工具必须写文件 |
| `NSStackView` 界面卡死不显示 | 子视图约束了 `equalTo: stack.widthAnchor`（布局死锁），改 `equalToConstant` |
| 面板 outlet 为 nil 崩溃 | `popover.contentViewController = panel` 之前没有 `_ = panel.view` 强制加载 |

## 6. 环境事实（当时）

| 项 | 值 |
| --- | --- |
| macOS | 27.0.0 arm64 |
| Swift | 6.4.2（Xcode 工具链） |
| JDK / jadx | OpenJDK 21.0.13 / jadx 1.5.6 |
| adb | 1.0.41 / 37.0.1 |
| 手机 | 一加，Android 17（SDK 37） |
| App | `com.antgroup.aijk.android` 1.1.78.2100，minSdk 24 / targetSdk 35 |
| 蓝牙权限 | `BLUETOOTH_SCAN` / `CONNECT` / `ADVERTISE` / `PRIVILEGED` / `ACCESS_BACKGROUND_LOCATION` |
