---
name: afu-wl-scale
description: |
  Talk to the 蚂蚁阿福 × 沃莱科技 (AFU-WL) **co-branded** body-fat scale (货号 A1,
  型号 FG2508WB / 上报型号 FG2313UWB-D) over BLE from macOS: connect, decode
  weight / impedance / history frames of the icomon 27 protocol, and compute the
  full body-composition metric set locally. Also covers the relevant parts of
  the Ant Fortune "阿福" (com.antgroup.aijk.android) app.
  Use when working with THIS specific scale and icomon ICWeightScale27Worker.

# ⚠️ Applicability — read this first

**This skill is specific to ONE product: the 蚂蚁阿福 × 沃莱科技 (Ant-Fu × Welland)
co-branded body-fat scale.**

| | |
|---|---|
| Co-brand | 蚂蚁阿福 × 沃莱科技 (AFU-WL) |
| 货号 (article no.) | **A1** |
| 型号 (model, box) | **FG2508WB** |
| Model reported over BLE | `FG2313UWB-D` |
| BLE name prefix | `AFU-WL` (`AFU-WL-TZ-A1`) |
| Protocol | icomon 27 (`ICWeightScale27Worker`, deviceSubType 7) |

It is **NOT guaranteed** to work for any other scale that Ant Fortune 阿福
partners with. Other AFU / icomon scales may use a different subType, a different
protocol version (V3 / general / 9 / 10), different service UUIDs, different
metric frames, or a different body-composition model. Verify these three things
before trusting anything here:

1. BLE name starts with `AFU-WL` (icomon only accepts that prefix —
   `ICBleHandler.java:1702`), **and**
2. it advertises service `0000FFB0` with `FFB1` write / `FFB2` notify, **and**
3. `deviceSubType == 7` (advertised byte `& 0x0F`), which is what routes it to
   `ICWeightScale27Worker` (`ICWorkerManager.java:768-777`).

If any of those differ, treat this skill as a *methodology* (how to reverse an
icomon/AFU scale) rather than a recipe, and re-derive the frames.
---

# AFU-WL scale (icomon 27 protocol)

A working, fully decoded BLE path from a Mac to an **AFU-WL-TZ-A1 / FG2313UWB-D**
body-fat scale (蚂蚁阿福 × 沃莱科技, 货号 A1, 型号 FG2508WB). Everything below was
verified against live traffic, not inferred.

> This skill ships with **synthetic demo values** only. Every height / weight / body-fat /
> age / impedance figure in these files is fake. Substitute your own profile at runtime
> via the `AFU_*` environment variables (see below) — never bake a real person in.

## When to use

- Connect to the scale and read weight / impedance / body composition on a computer.
- Decode an `icomon` (伊康) based scale: service `0000FFB0`, characteristic `FFB1` write / `FFB2` notify.
- Reverse an Android app's BLE protocol (`com.antgroup.aijk.android` is the worked example).
- Debug macOS Bluetooth permission problems in a CLI tool.

## Fast path

```bash
# AFU_H / AFU_K / AFU_AGE / AFU_SEX / AFU_UUID come from the environment
swiftc -O assets/afuscale.swift -o /tmp/afuscale_new
cp /tmp/afuscale_new AFUProbe.app/Contents/MacOS/afuprobe   # reuse an authorized bundle
rm -rf AFUProbe.app/Contents/_CodeSignature
codesign --force --deep --sign - AFUProbe.app
open -n ./AFUProbe.app --args 1800 with-writes
cat /tmp/afuscale.out
```

Output per measurement (values below are synthetic):

```
[WEIGHT]  ... weight_g=78400 weight=78.40kg state=1 ...
[ADC]     ... adcs=[500, 514] imp=[500.0, 514.0]Ω alg=41
BODY      fat=24.6% fatKg=19.3 FFM=59.1 water=37.3kg(47.6%) ... BMR=1647kcal BMI=25.6 Zavg=507.0
```

The scale only accepts a connection while it is awake (2–3 min after being stepped on).
A 10 s connect timeout with retry is normal and expected.

## Read these before working

| Topic | File |
|---|---|
| Frame bytes, GATT tree, writes, checksum, history replay | [references/protocol.md](references/protocol.md) |
| Body-composition model, coefficients, calibration anchors | [references/body-model.md](references/body-model.md) |
| What the AFU app actually does (icomon SDK, server-side fat, log locations) | [references/app-internals.md](references/app-internals.md) |
| macOS TCC / codesign traps, adb & bugreport recipes | [references/tooling.md](references/tooling.md) |

## Non-negotiables

- **BLE is 1:1.** While a tool holds the connection the phone app gets nothing, and vice
  versa. Always `pkill -f afuprobe` when done so the app can sync.
- **Run through an already-authorized `.app`.** A fresh bundle silently gets no
  CoreBluetooth callbacks. Reuse an authorized bundle as the host binary.
- **Do not reset the scale** to "fix" missing body fat. Write the user-info frame with
  `fun_open_imp = 1` instead (see protocol.md, "writes").
- Raw frames are append-only; measurements may be deleted only from the app's own
  「记录」 window (by id). Never edit the SQLite file by hand while the app is running.

## Menu-bar app (ScaleBar)

The same protocol wrapped in a persistent status-bar app. It now lives in its own
SwiftPM repo (`~/Workspaces/ScaleBar`: `ScaleBarCore` + `ScaleBar`, `./build.sh` →
`.app` + `.dmg`, CI on every push); the original scratch single file
- **Idle = passive scan only.** It listens for `AFU-WL*` advertisements and never
  connects, so the phone app keeps working.
- **Capture on demand.** Click 接收数据 → connect, write the time frame, wait for a
  `state=1` `0xD5` plus a non-zero `0xD6`, compute, store, disconnect back to idle
  (180 s / 120 s timeouts). The button turns into 停止 while a session is open.
- **Panel** shows 14 metrics in two aligned columns (Chinese names; acronyms such as
  BMI/FFM live in the row tooltip and the 「指标 ?」 help sheet), impedance / last-change
  on a separate line, two trend charts (weight, body-fat with the healthy band), a
  body-composition bar, and a 1周/1月/3月/半年/1年/全部 period control that only
  filters the charts.
- **Storage:** one SQLite file at
  `~/Library/Application Support/ScaleBar/scaledata.sqlite`, managed by the app —
  tables `measurements` (time / weight / z1 / z2 / fatPct), `frames` (every raw frame,
  in and out) and `settings` (profile: heightCm / birthYear / sex / k). Charts recompute
  history when the profile changes. Use 「导出」 to write CSV or JSON via NSSavePanel.
  「记录」 lists records and deletes selected ones by id.
- **Build:** `./build.sh` (SwiftPM; the packaged app declares the Bluetooth usage
  strings in its Info.plist). The app icon
  is generated by `scripts/make_icon.py` and bundled as `AppIcon.icns`.
- **Screenshots** in the repo README/docs use only synthetic demo data
  (`SCALEBAR_DB=/tmp/demo_scalebar.sqlite`, 175 cm / 1984 / male / 78.40 kg).

Layout constraints: `NSStackView` children must never be constrained
`equalTo(_:stack.widthAnchor)` (layout deadlock, `loadView` never returns) — use
`equalToConstant`; and `_ = panel.view` must run *before* `popover.contentViewController`
or the outlets are nil and `refresh()` crashes.

## Reference client

`assets/afuscale.swift` is the complete working implementation: scan, connect, subscribe,
write time / user-info / history-ack frames, decode `0xD5` `0xD6` `0xD8` `0xDF`, and compute
all metrics. Profile constants are read from the environment with placeholder defaults.
