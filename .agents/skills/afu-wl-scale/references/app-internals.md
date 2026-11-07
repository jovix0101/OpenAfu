# What the 阿福 app does (com.antgroup.aijk.android)

Verified on Android 17 / OnePlus PKX110, app 1.1.78.2100 (versionCode 2761).

## Two BLE stacks are bundled

| stack | package | service | used for |
|---|---|---|---|
| icomon (伊康) | `cn.icomon.icdevicemanager` — `@MpaasClassInfo(BundleName="com-antgroup-aijk-android-product_wellandbodyfatscale")` | `FFB0` | **this scale** |
| AFU hardware SDK | `com.antgroup.aijk.android.aijk_hardware_sdk` + `com.afu.afudevicemanager` | `FC50` | other AFU devices |

The scale is 沃莱 (Welland) hardware, so it goes through icomon. Do not chase `FC50` for it —
that path never fires (its scan gate `x8.java:86` logs
`"scan ignored, no valid AFU 0xFC50 service data, ..."`).

## Key app facts

- The app connects **silently in the background** on every weigh-in, holds the link 7–70 s,
  then unregisters. Evidence in `dumpsys bluetooth_manager` → `GATT Client Map`:
  `AppRecord(..., id=110, appName=com.antgroup.aijk.android, transport=AUTO,
  reason=REASON_UNREGISTER_CLIENT)`.
- `updateInfo()` is called on every notify-subscribe, i.e. every sync. It writes the user
  profile **including `fun_open_imp`** — this is how impedance measurement silently gets
  disabled, and why re-writing the frame (protocol.md) restores it.
- Body fat is computed **server-side** (`ICAlgorithmManager.calc` is a stub, `aq/wlbfs/*`
  only uploads). No local formula exists to reuse — see body-model.md.
- The app registers **one** MiBeacon product id, `14623` (0x391F), via
  `AFUDeviceManagerConfig.java:43-48`. Other vendors' MiBeacon broadcasts are dropped
  (`ICDeviceManager.java:2439-2455` returns null when `getMIDeviceByProductId` misses).
- Device logs are **not** in logcat. `AFULoggerHandler` writes to
  `getFilesDir()/afu/afublesdklogcache`, `ICLoggerHandler` to
  `/icomon/ + /dmlogs + /cache` — both private. Only
  `com/afu/wearable/sdk/logging/AfuFirmwareFrameLogger.java` uses `android.util.Log`.
- `run-as` fails: `package not debuggable`. The external data dir holds only multimedia caches.

## Don't confuse it with a Xiaomi scale

A nearby **Mijia Scale S400** advertises MiBeacon `FE95` with
`sdata = 10 59 d9 30 <counter> <mac>`, i.e. frame control `0x5910`, product `0x30D9` (12505),
**no object field**, and a counter that barely moves. It has zero `[Packages]` entries in the
Bluetooth device cache and never pairs. It is not the target device, and the MiBeacon bindkey
route (ESPHome `xiaomi_body_scale`, HA `xiaomi_ble`) is a dead end for this scale.

Useful check: the icomon scan drops anything whose name does not start with `AFU-WL`, so a
mismatch between "a scale is right next to me" and "no scale is discovered" is almost always
the wrong physical device, not a bug.

## Recovering app data from the phone

```
adb exec-out screencap -p > shots/app_health.png
adb shell dumpsys bluetooth_manager | grep -A30 "GATT Client Map"
adb bugreport bug.zip          # ~63 MB, holds historical BT logs
```
`logcat`'s main ring is 256 KiB and is flooded by system noise — useless after the fact.

The 身材管理 page renders the twelve metrics as
`体重 78.40 | 25.6 BMI·标准 | 24.6% 体脂率·标准 | 2项异常 | 数据来源：…体脂秤`.
Screenshots are the only way to read values that live server-side.
