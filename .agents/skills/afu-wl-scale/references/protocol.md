# icomon 27 protocol — wire format

Reversed from `com.antgroup.aijk.android` 1.1.78.2100 / 1.1.76.8000
(`cn.icomon.icdevicemanager` bundled as "阿福三方SDK / wellandbodyfatscale"),
then verified against live traffic from an **AFU-WL-TZ-A1** scale.

Decompiled sources referenced below come from a local jadx run; package/class names are stable,
line numbers are not.

> All frame examples below decode to **synthetic demo values** (78.40 kg, 175 cm, 42 y).

## GATT

| | |
|---|---|
| Name | `AFU-WL-TZ-A1` (icomon only accepts names starting with `AFU-WL`, `ICBleHandler.java:1702`) |
| Service `0000FFB0-0000-1000-8000-00805F9B34FB` | main protocol |
| → `FFB1` | write **without response** (all commands) |
| → `FFB2` | notify (all inbound frames) |
| Service `0000180A` | 2A27 hw `1.1.0`, 2A28 fw `1.2.2`, 2A29 `ICOMON`, 2A24 `FG2313UWB-D`, 2A23 all zeros, 2A50 PnP |
| Service `00001530-1212-EFDE-1523-785FEABCD123` | Nordic DFU (`1531`/`1532` wn, `1534` r) — unused |

## Advertising

Service data under UUID `27AC`: `a1 c7 25 00 5c d0 01`.
(The last 3 bytes vary per unit; they are not the MAC — the MAC is not advertised.)

`ICBleHandler` rewrites it by swapping the two UUID bytes and prefixing them, giving
`manfactureData = AC 27 a1 c7 25 00 5c d0 01`. From that:

| byte | meaning | value |
|---|---|---|
| 0 | magic | `0xAC` (must equal 172) |
| 1 | mode + type + subtype packed | `0x27` |
| | bit7 | 0 → **Connect** required, 1 → Broadcast-only |
| | `(b & 0x70) >> 4` | 2 → **FatScale** (1 WeightScale, 3 Balance, 4 Kitchen, 5 Ruler, 6 Skip) |
| | `b & 0x0F` | **7** → deviceSubType, selects the worker |
| 8 | protocol_ver | `0x01` |

`ICWorkerManager.getNormalWorkerNameByScanModel` — subtype 7/9/10 → `ICWeightScale27Worker`,
8/11/12 → `ICWeightScaleV3Worker`. This scale is subtype 7.

Advertised services are `FFB0` + `1530`. There is **no FC50 service data** — the AFU
`0000FC50` protocol belongs to a different device family and this scale never emits it.
Its advertisement carries **no weight**: the payload is identical on every packet,
before and during a measurement.

## Frames — 20 bytes, fixed

```
[0]  0xAC         header
[1]  device type  0x27 = connect|7 (what we send); 0x29 appears in scale→host frames
[2..17]           payload (16 bytes)
[18]              command
[19]              checksum
```

**Checksum** = `sum(bytes 2..18) & 0x1F` (low 5 bits). The scale emits exactly that. Writing
`sum & 0xFF` is also accepted, because 256 is a multiple of 32 so the low 5 bits always agree.

### `0xD5` weight — live stream

```
ac 29 | 80 09 32 40 | 02 | 00 05 40 00 | 64 | 00 00 00 00 00 | 29 | d5 | a4
        core (4B BE)  mode    funs(u32)  batt     (reserved)    alg
```

`core` is **big-endian** (the Java reader sets little-endian then `ReadInt` without swap —
see `ICStreamBuffer.java:305`):

| bits | field |
|---|---|
| 0–17 | `weight_g` (`core & 0x3FFFF`) |
| 18–20 | `kg_division` (`0x1C0000 >> 18`) |
| 21–23 | `lb_division` (`0xE00000 >> 21`) |
| 24 | `dianji` (electrode count: 1 → 8 electrodes, 0 → 4) |
| 25–28 | supportHr / supportPh / supportZx / has_temperature |
| 31 | `state` — **1 = locked/final** |

Decoding the example: `0x80093240` → `weight_g = 0x13240 = 78400`, `kg_division = 2`,
`state = 1` → **78.40 kg**.

`mode` (payload byte 4) selects the trailer layout: `2` → `support_funs` u32 at 5, battery
at 9 (0 means 255); `1` → calibMode, battery, charging, overWeight. Observed always `2`
with `supportFuns = bits 14,16,18`.

Weight conversion — `ICCommon.gunit_general`, `div` = `kg_division`:

```
div 0: (ms + 5) / 10 / 100
div 1: (ms % 10 == 9 ? ms + 10 : ms) / 10, then round up to even, / 100
div 2: i6 = (ms + 20) / 10; (i6 % 10 >= 5 ? (i6/10)*10 + 5 : (i6/10)*10) / 100
div 3: (ms + 5) / 10 / 10            # jin
```
`ms` is `weight_g`; `div 2` is what this scale uses (0.05 kg steps).

### `0xD6` impedance / ADC

```
ac 29 | 02 | 00 | 01 f4 | 02 02 | 01 | 80 09 32 40 | 00 00 00 00 | 29 | d6 | f6
        n    ??   adc0    adc1    mode   core (BE)                   alg
```
`n` = number of impedance values; each `adc` is a big-endian u16 at payload `2 + 2k`.
`mode = 1` → a `core` follows at payload `3 + 2n`, same bitfield as `0xD5`.
Example decodes to `imp = [500.0, 514.0] Ω`, weight 78.40 kg, `alg = 41`.

Raw → ohms (only when `raw >= 1500`, `ICWeightScale27Worker.java:487-500`):

```
imp = ((raw - 1000.0) + weight_kg * 10.0 * -0.4) / 0.6 / 10.0
```

Multi-value mapping: 5 values → `imp = list[4], imp2..imp5 = list[0..3]`; 4 → in order;
3/2/1 → in order. This scale sends **2** values (left/right foot).

`adcs=[0, 0]` means **no measurement happened** (socks on / feet off the electrodes, or
`fun_open_imp` was written as 0). It is not a device fault.

### `0xD8` history record

```
ac 29 | 01 | 68 f2 a1 c4 | 80 09 32 40 | 00 | 00 | 00 00 00 00 | 29 | d8 | bc
        kind  time(4B BE)   core(BE)      remain count           alg
```
`kind 0` adds `hr` + count + adcs; `kind 2` adds remain + count + adcs; other kinds put
two adcs + 2 skip bytes. Field offsets start at payload index 9.

**The scale replays unacknowledged history every 1.5 s until acked** — this was the first
thing observed on connect (4 identical frames). Send the `history-ack` write below.

Watch out: the scale RTC can be badly wrong (one record read back years in the future).
Treat the timestamp as advisory.

### `0xDF` settings — not decoded; log the payload.

## Writes (host → scale), all via `FFB1` without response

`ICBleScale27Protocol.encodeSetting` = `AC, device_type, operate_type, …pad…, 0xD0, cksum`:

```
time frame   ac 27 08 82 97 ec 6a 20 00×10 df 76
history ack  ac 27 04 d8 00×14 df bb          # operate_type=4, reply_cmd=216
```

`encodeTimeAndUserInfo` (`encode(1)`) — **no operate_type byte**, time comes right after
device type:

```
ac 27 | <time int32 LE> | <utc/900> | unit | user_index | height | <weight*100 u16 LE>
      | age | sex | <target*100 u16 LE> | flags | 00 | d0 | ck
```

Example (synthetic profile: 175 cm, 42 y, male, 78.40 kg, impedance enabled):

```
ac 27 82 97 ec 6a 20 00 01 af a0 1e 2a 01 a0 1e 01 00 d0 b7
```

- `unit` 0 kg / 1 lb / 2 st / 3 jin; `sex` 1 male / 2 female; `peopleType` 1 (sportsman) sets
  bit15 on the weight field; `flags` bit0 = `fun_open_imp`, bit1 = little-weight, bit4 = baby mode.
- `utc_offset/900` → 32 for UTC+8.

**`fun_open_imp` is the switch that turns impedance measurement on.** The phone app wrote
`0` during a sync session and the scale then reported weight only, for every subsequent
weigh-in, until the frame above was written back with `flags = 0x01`. This is the fix for
"the scale only shows weight now" — resetting the scale is not needed and loses the pairing.

Other operate types: `6` readSign, `9` readAFUSign, `10`/`7` replyReadSign.
`sendReplyCMD(x)` is the same `operate_type=4, reply_cmd=x` frame — the app sends `214`
after an ADC result and `216` after a history record.

## Session shape

```
connect → discoverServices
        → read 180A identity
        → setNotify(FFB2)
        → WRITE time frame            (scale starts streaming ~120 ms/frame)
        → [optional] WRITE history-ack, WRITE user-info
        → 0xD5 stream … 0xD6 impedance ~2-3 s after lock … heartbeat 0xD6 every 1.5 s
        → scale disconnects itself after ~70 s idle (CBErrorDomain Code=7)
```

## Tells that a frame is not this protocol

`180A` characteristic reads (ASCII version strings) and Nordic DFU traffic also arrive on
the same peripheral — gate on `b.count == 20 && b[0] == 0xAC`.
