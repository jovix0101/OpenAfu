# Tooling: macOS BLE, reverse-engineering, capture

## macOS Bluetooth permission (the big trap)

A plain binary — including `python3` + `bleak` — cannot use CoreBluetooth. It dies with:

```
Attempting to access privacy-sensitive data without a usage description.
The app's Info.plist must contain an NSBluetoothAlwaysUsageDescription key
```

`bleak` does not raise an exception; the process `SIGABRT`s. The crash report names the
*responsible* app (terminal, IDE), not your script.

A new `.app` bundle with the right `Info.plist` is **not** enough either: a freshly created
bundle was granted TCC but delivered **zero** CoreBluetooth delegate callbacks — it printed
its first log line and went silent while `CBMsgIdRetrievePeripheralsWithIdentifiers` kept
firing.

**Working recipe:** reuse an already-authorized bundle as the host.

```bash
cp mytool SomeApproved.app/Contents/MacOS/<its executable name>
rm -rf SomeApproved.app/Contents/_CodeSignature
codesign --force --deep --sign - SomeApproved.app
open -n ./SomeApproved.app --args <seconds> <mode>
```

`open` detaches stdout, so **always log to a file** (env `BLE_OUT`, default `/tmp/*.out`).

## Swift delegate labels

Optional-protocol methods must end in `error:`. `didDiscoverServices e:` /
`didUpdateValueFor ch:, e:` compile with only a "nearly matches optional requirement"
warning and then **never fire**. This wastes an hour every time.

## Peripheral availability

Scales sleep. The device is only connectable during a short window after being stepped on.
Expect `connect timeout` retries; loop with a 10 s timeout and keep retrying.
`retrievePeripherals(withIdentifiers:)` succeeds from the cached UUID even when nothing is
advertising, but the connect itself still fails until the device wakes.

## adb

```bash
adb devices -l                    # phone rotates its mDNS serial frequently
export ANDROID_SERIAL=adb-xxxxx   # required when a TV is also attached, else
                                  # "adb: more than one device/emulator"
adb bugreport bug.zip             # ~63 MB; historical BT stack logs live inside
```

The bugreport contains `FS/data/misc/bluetooth/logs/bluetooth_*.log` but **no
btsnoop_hci.log**. `settings put global bluetooth_hci_log 1` succeeds, yet the file stays
unreadable without root.

## Passive sniffing (no connection)

Advertising-only tools are the safe way to identify a device:
`CBCentralManagerScanOptionAllowDuplicatesKey: true`, never `connect`. Print
`[time] name rssi= sdata(UUID)= | svc=[..] | mfr=`. Useful to prove a device never
advertises a given service, or to catch which byte changes during a measurement.

## Android APK analysis without a JDK

```bash
curl -sSL -o /tmp/jdk21.tar.gz "https://mirrors.tuna.tsinghua.edu.cn/Adoptium/21/jdk/aarch64/mac/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.13_9.tar.gz"
tar xzf /tmp/jdk21.tar.gz -C tools/
JAVA_HOME=$PWD/tools/jdk-21.0.13+9/Contents/Home /tmp/jadx_out/bin/jadx \
  -d decomp/app --no-res --show-bad-code -j 8 app.apk
```

jadx needs ~4 min for 51 k classes; `finished with errors, count: 427` is normal.
Fast class listing without a JDK: `androguard`, but `DEX(...)` needs
`open(f,'rb').read()`, not a path string.

## BLE is 1:1

A peripheral serves one central at a time. Holding the connection from the Mac silently
starves the phone app, and *vice versa*. Always release:

```bash
pkill -f "App/Contents/MacOS/tool"
```
