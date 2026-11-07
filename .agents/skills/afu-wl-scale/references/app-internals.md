# What the 阿福 app does (com.antgroup.aijk.android)

Verified on Android 17 / OnePlus PKX110, app 1.1.78.2100 (versionCode 2761).

## Two BLE stacks are bundled

| stack | package | service | used for |
|---|---|---|---|
| icomon (伊康) | `cn.icomon.icdevicemanager` — `@MpaasClassInfo(BundleName="com-antgroup-aijk-android-product_wellandbodyfatscale")` | `FFB0` | **this scale** |
| AFU hardware SDK | `com.antgroup.aijk.android.aijk_hardware_sdk` + `com.afu.afudevicemanager` | `FC50` | other AFU devices |

The scale is 沃莱 (Welland) hardware, so its data path goes through icomon (`FFB0`).

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
- Device logs are **not** in logcat. `AFULoggerHandler` writes to
  `getFilesDir()/afu/afublesdklogcache`, `ICLoggerHandler` to
  `/icomon/ + /dmlogs + /cache` — both private. Only
  `com/afu/wearable/sdk/logging/AfuFirmwareFrameLogger.java` uses `android.util.Log`.
- `run-as` fails: `package not debuggable`. The external data dir holds only multimedia caches.

## Device identification

The icomon scan drops anything whose name does not start with `AFU-WL`
(`ICBleHandler.java:1702`). Discoverability is decided by the advertised name plus
service `0000FFB0` with `FFB1` write / `FFB2` notify.

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
