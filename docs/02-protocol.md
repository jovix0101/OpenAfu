# 02 · BLE 协议规格（icomon 27 / AFU-WL-TZ-A1）

> 本文的字节、位域、行号全部来自对 App 内 icomon SDK 的静态逆向 + 真机抓包交叉验证。
> 帧样本用**合成演示值**（78.40 kg / 阻抗 500、514 Ω），不是真实测量记录。

## 0. 先确认是不是这台秤

三条都满足才适用本文（任何一条不符，请当「方法论」而不是「配方」重新推）：

1. BLE 广播名以 **`AFU-WL`** 开头（本机是 `AFU-WL-TZ-A1`）。icomon 的 `ICBleHandler.java:1702` 写死 `if (str3 == null || str3.isEmpty() || !str3.startsWith("AFU-WL")) { return; }`，不是这个前缀直接丢弃。
2. 广播 / GATT 里有服务 **`0000FFB0-0000-1000-8000-00805F9B34FB`**，特征 `FFB1`(write without response) / `FFB2`(notify)。
3. 广播字节解出的 **`deviceSubType == 7`**，`ICWorkerManager.java:768-777` 会把它路由到 `ICWeightScale27Worker`。

| 项目 | 值 |
| --- | --- |
| 联名 / 货号 / 盒上型号 | 蚂蚁阿福 × 沃莱科技 / A1 / FG2508WB |
| BLE 上报型号（`180A/2A24`） | `FG2313UWB-D` |
| 厂商（`2A29`） / 硬件（`2A27`） / 固件（`2A28`） | `ICOMON` / `1.1.0` / `1.2.2` |
| 协议 | icomon `ICBleScale27Protocol`，`alg_type = 41`（WLA41） |
| 加密 / 配对 | **都没有**，BLE 明文连接，不做系统配对 |

## 1. 广播

单条实测广播（数值为合成示意）：

```
name   AFU-WL-TZ-A1
rssi   -65 ~ -74
svc    [FFB0, 1530]                 # 1530 = Nordic DFU
sdata(27AC)  a1 c7 25 00 5c d0 01    # 7 字节
mfr    4c 00 02 15 <iBeacon 16B UUID> <major> <minor> <tx> c4
```

`ICBleHandler.java` 把 16-bit service data 的 key 反转成 `AC 27`，再拼上 value，得到：

```
manufactureData = AC 27 a1 c7 25 00 5c d0 01
                  │  │
                  │  └─ 0x27: bit7=0 → Connect 模式；(b & 0x70)>>4 = 2 → FatScale；b & 0x0F = 7 → deviceSubType
                  └──── 0xAC: 协议魔数
```

- `bit7 = 1` 才是「纯广播模式」（免连接拿数据），这台是 `0`，**必须连接**。
- 广播里**没有体重**，只有协议标识、版本、状态位。连续抓 30 分钟，除 frame counter 外字节不变。
- 秤只在被踩醒后的约 2～3 分钟里广播；测完就停，之后 `connect` 全部超时是正常现象，不是工具坏了。

## 2. GATT 树

| 服务 | 特征 | 属性 | 用途 |
| --- | --- | --- | --- |
| `0000180A-0000-1000-8000-00805F9B34FB` | `2A23` / `2A24` / `2A27` / `2A28` / `2A29` / `2A50` | read | 设备信息（型号、固件、厂商、PNP） |
| `00001530-1212-EFDE-1523-785FEABCD123` | `1531`/`1532` wn、`1534` r | — | Nordic DFU，与称重无关 |
| **`0000FFB0-...`** | **`0000FFB1-...`** | write without response | 主机 → 秤：时间 / 用户信息 / 历史确认 |
| 同上 | **`0000FFB2-...`** | notify | 秤 → 主机：20 字节数据帧 |

写入一律用 `.withoutResponse`；`FFB2` 必须先 `setCharacteristicNotification(true)`，秤才会开始推帧。

## 3. 帧的通用形状

**所有通知帧恒 20 字节**：

```
idx  0    1    2..17                          18     19
     AC   dev  载荷（16 字节）                cmd    checksum
```

| 字段 | 说明 |
| --- | --- |
| `b[0]` | `0xAC` 帧头 |
| `b[1]` | 设备类型；通知帧实测为 `0x29`，主机写出去的帧是 `0x27`（`getDeviceType()` = `deviceSubType｜32`）。解析不依赖它 |
| `b[18]` | 命令字：`0xD5` 体重 / `0xD6` 阻抗 / `0xD8` 历史 / `0xDF` 设置 |
| `b[19]` | **校验和 = `sum(b[2..18]) & 0x1F`**（只取低 5 位）。客户端写 `sum & 0xFF` 也能通过，因为 256 是 32 的倍数、低 5 位相同 |

校验和取模 32 这个细节很坑：按「整字节和」去验证真实抓包会全部判错。

### 端序（另一个大坑）

`ICStreamBuffer.ReadInt()` 先按 `(b0<<24)|(b1<<16)|(b2<<8)|b3` 组装，再 `if (!m_bLittle) ConvertIntEndian(i)`。而 `decodeWeightData` / `decodeAdcData` 里设了 `SetLittleEndian(true)` → **不交换，最终值是大端**。

- 通知帧里的 `core`、`adc`、`time`（历史帧）→ 大端读。
- 主机写出去的时间帧 / 用户信息帧里的 int32 / short → 小端写。

## 4. `0xD5` 体重帧

合成样本：

```
ac 29 80 09 32 40 02 00 05 40 00 64 00 00 00 00 00 29 d5 a4
```

`b[2..5]` 是 32 位 `core`（大端），位域：

| 位 | 含义 |
| --- | --- |
| `0..17` (`0x3FFFF`) | `weight_g`，克 |
| `18..20` (`0x1C0000`) | `kg_division` |
| `21..23` (`0xE00000`) | `lb_division` |
| 24 | `dianji`（多电极；1 → 8 电极，0 → 4 电极） |
| 25 / 26 / 27 | `supportHr` / `supportPh` / `supportZx` |
| 28 | `has_temperature` |
| **31** | **`state`：1 = 读数已锁定**（只有这个才能当一次测量存档） |

样本 `core = 0x80093240` → `weight_g = 78400`（78.40 kg）、`kg_division = 2`、`lb_division = 0`、`state = 1`。

`b[6]` 是 `mode`：

- `mode == 1`：`b[7]` calibrationMode、`b[8] & 0x7F` battery、`b[8] >> 7` charging、`b[9]` overWeight。
- `mode == 2`：`b[7..10]` 是 `support_funs` 位图、`b[11]` battery（0 视为 255）。

克 → 千克不是简单除 1000，要复刻 `ICCommon.gunit_general(g, division, precision)` 四个分支（`src/afuscale.swift` / ScaleBar 的 `Units.swift` 有可运行实现）。`kg_division ∈ {0,1,2}` 时 `precision_kg = 2`，否则 1。

测量过程中 `state = 0` 的瞬态帧约 120 ms 一条（上秤时重量会先冲高再回落），锁定后 `state = 1` 的帧会重复若干条；**不要按帧数计次，按 `state` 的边沿 + 时间去重**。

## 5. `0xD6` 阻抗帧（体成分的输入）

合成样本（78.40 kg，阻抗 500 / 514 Ω）：

```
ac 29 02 00 01 f4 02 02 01 80 09 32 40 00 00 00 00 29 d6 f6
```

载荷 `p = b[2..17]`：

```
n      = p[0]                       # ADC 个数，1..5
adcs   = [u16be(p, 2+2k) for k in 0..<n]
mode   = p[2+2n]                    # 必须 == 1
core   = u32be(p, 3+2n)             # 与 0xD5 相同的位域，含 weight_g / state
alg    = b[17]                      # 算法类型，本机 41 (0x29) → WLA41
unit   = (b[19] & 0xE0) >> 5        # SDK 从末字节高 3 位取单位：0 kg / 1 lb / 2 st / 3 斤
                                     # （末字节低 5 位才是校验和，见 §3）
```

样本 `n=2`、`adcs = [500, 514]`、`mode=1`、`core = 0x80093240` → 78.40 kg、`state=1`。

`ICWeightScale27Worker.java:487-500` 把 adcs 映射到 `imp / imp2 …`（`size==5` 时顺序是 `[4,0,1,2,3]`），并且：

```text
if (v >= 1500.0) v = ((v - 1000.0) + (weight_kg * 10.0 * -0.4)) / 0.6 / 10.0
else             v = v                      # <1500 直接当 Ω
```

本机两路都在几百 Ω，所以直接就是 Ω。

**时序**：体重锁定后还要等 2～3 秒秤才测阻抗，通常连续来 4 帧左右。如果 `adcs = [0, 0]`，说明这一次没测到阻抗（脚没贴在电极上，或配置位被关了，见 §8）。

## 6. `0xD8` 历史帧（离线记录）

合成样本：

```
ac 29 01 68 f2 a1 c4 80 09 32 40 00 00 00 00 00 00 29 d8 bc
```

`ICBleScale27Protocol.decodeHistoryData` 的结构：

```
kind = b[2]                    # 1 = 普通记录；42 = 另一种格式
time = u32be(b[3..6])          # Unix 秒；可能明显错乱，超出 2020–2100 要丢弃
core = u32be(b[7..10])         # 同 §4 位域
kind==0 → 心率 + N×adc
kind==2 → remainingHistoryCount = b[?]，随后 N×adc
其它    → 跳过若干 short
末尾    → alg_type、unit
```

**必须回 ACK**，否则秤会每 1.5 秒把同一条记录重发一次（我们曾经因此误以为有十几条离线记录）。ACK 见 §7。收到历史帧后 App 侧还有一层去重：`ICWeightScale27Worker.java:605-616` 里 `if (time == _nLastHistoryTime) { log "filter history data with same time:%d"; return; }`。

## 7. 主机写出去的三种帧

全部 20 字节，末尾追加 `sum(b[2..18])`（写全 8 位也能过）。`ICBleScale27Protocol.encodeSetting` 的最后 `WriteByte(BuildConfig.VERSION_CODE)` 是 `0xDF`。

### 7.1 时间帧（`operate_type = 8`，连上后第一件事）

```
AC 27 08 | time(int32 LE) | utc_offset/900 | 00 … 00 | DF | checksum
```

合成：`ac 27 08 82 97 ec 6a 20 00 00 00 00 00 00 00 00 00 00 df 76`

`time = System.currentTimeMillis()/1000`，`utc_offset = TimeZone.getDefault().getOffset()/1000`（东八区 = 28800 → `/900 = 32 = 0x20`）。写完秤才开始推数据帧。

### 7.2 用户信息帧（`encode(1) = encodeTimeAndUserInfo`）

```
AC 27 | time(int32 LE) | utc/900 | unit | user_index | height(cm)
      | weight×100(short LE) | age | sex(1男/2女) | target×100(short LE)
      | flags | 00 | D0 | checksum
```

`flags`: bit0 = `fun_open_imp`（**体脂测量总开关**）、bit1 = 小体重模式、bit4 = 婴儿模式。

合成（175 cm / 42 岁 / 男 / 78.40 kg）：

```
ac 27 82 97 ec 6a 20 00 01 af a0 1e 2a 01 a0 1e 01 00 d0 b7
```

注意 `b[2]` 是 `time` 的最低字节，**不是** operate_type —— 这一帧走的是 `encode(1)`，不是 `encodeSetting`。`weight×100` 用 `ICCommon.float2int(kg, 2)`。

### 7.3 历史确认 / 回复（`operate_type = 4`）

```
AC 27 04 | reply_cmd | 00 … 00 | DF | checksum
```

`reply_cmd = 216 (0xD8)` 确认历史记录；`214` = 传感器开始、`215` = 传感器结束（`ICWeightScale27Worker.sendReplyCMD`）。

合成：`ac 27 04 d8 00 00 00 00 00 00 00 00 00 00 00 00 00 00 df bb`

## 8. 会话时序与常见故障

```
t+0.0s    scan 命中 AFU-WL* → connect（10s 超时重试，秤休眠时重试是正常的）
t+3.5s    discoverServices → 订阅 FFB2 → 写时间帧
t+3.6s    0xD5 开始，120ms/帧（state=0 瞬态）
t+6s      体重稳定，state=1
t+8~9s    0xD6 阻抗帧 ×4（体脂的输入）
t+…       若有 0xD8 → 立刻回 history-ack(216)
t+45~70s  秤主动断开，停止广播
```

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 连上但一帧都没有 | 没写时间帧 / 没订阅 `FFB2` | 补上两件事 |
| 只有体重，`0xD6` 恒 `[0, 0]`，秤屏也不再显示体脂 | `fun_open_imp` 被写成 0（App 连接时写用户信息帧导致） | 写用户信息帧，`flags \|= 1`，带上真实身高/年龄/性别。**不要重置秤** |
| 同一条 `0xD8` 每 1.5 秒重发 | 没回 ACK | 发 `operate_type = 4, reply_cmd = 0xD8` |
| 体重算出几万公斤 | 把 `core` 按小端读了 | 通知帧是大端 |
| 所有帧校验都失败 | 按 `sum & 0xFF` 严格比对 | 只比较低 5 位 |
| 手机 App 没收到这次数据 | BLE 1:1，电脑占着连接 | 测完立刻断开；平时工具只被动扫描 |

## 9. 与 App 代码的对应关系

| 本文章节 | SDK 位置（jadx 反编译，未入库） |
| --- | --- |
| 广播解析 / `AFU-WL` 过滤 | `cn/icomon/icdevicemanager/manager/ble/ICBleHandler.java:1702-1750` |
| Worker 路由 | `…/manager/worker/ICWorkerManager.java:768-777` |
| 通道 UUID | `…/manager/worker/scale/ICWeightScale27Worker.java:51/54/56` |
| 连接后写时间 / 用户信息 | 同上 `:1052-1059`、`:1274`、`:1325`、`:1367` |
| 帧编解码 | `…/protocols/scale/ICBleScale27Protocol.java`：`decode :188`、`decodeAdcData :228`、`decodeWeightData :505`、`decodeHistoryData :306`、`encode :608`、`encodeSetting :634`、`encodeTimeAndUserInfo :670`、`splitData :1021` |
| 阻抗换算 / 稳定判定 | `ICWeightScale27Worker.java:483-580` |
| 单位换算 | `…/common/ICCommon.java:559` (`gunit_general`)、`:383` (`g2kg_general`)、`:394` (`g2lb_general`)、`:367` (`float2int`) |
| 端序 | `…/common/ICStreamBuffer.java:305` (`ReadInt`)、`:475` (`WriteInt`) |

逐字节可运行的合成样本与解析脚本见 [`../samples/frames.md`](../samples/frames.md)。
