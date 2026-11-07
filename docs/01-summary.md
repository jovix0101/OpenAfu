# 01 · 结论摘要

## 最初的三个问题

1. 蚂蚁阿福 App 是怎么从秤上拿数据的？
2. 能不能绕过 App，把秤的数据直接接到电脑上？
3. 拿到之后能做点什么有意思的？

三个都有答案：**走 BLE（不是 Wi-Fi、不是米家）→ 能，复刻 App 的连接会话即可 → 做成菜单栏常驻面板（ScaleBar）**。

## 数据链路

```
[踩上秤]
   │  秤被唤醒，2～3 分钟窗口内广播
   │  name = AFU-WL-TZ-A1
   │  service = 0000FFB0 (+ 1530 Nordic DFU)
   │  service data (27AC) = 7 字节，里面只有协议标识 / 版本 / 状态，不含体重
   ▼
[手机 App / 我们的工具 扫描到广播]
   │  icomon SDK 只接受名字以 AFU-WL 开头的设备
   │  → deviceSubType = 7 → ICWeightScale27Worker
   ▼
[建立 BLE 连接]（不配对、无加密、明文）
   │  服务 0000FFB0：FFB1 = write-without-response，FFB2 = notify
   │  订阅 FFB2 之后，立刻写「时间帧」
   ▼
[秤开始推帧，20 字节定长，约 120 ms / 帧]
   │  0xD5 体重帧   → 体重、单位、分度值、state（是否锁定）
   │  0xD6 阻抗帧   → 两路 ADC → 两路阻抗 Ω（体重锁定后 2～3 秒才来）
   │  0xD8 历史帧   → 秤里没同步过的离线记录（收到后要回 ACK，否则反复重发）
   ▼
[App 把「体重 + 阻抗」上传服务端] → 体脂 / 肌肉 / 水分 / BMR 等 12 项
   └─ 客户端算法类是空壳：体脂公式根本不在 APK 里
```

**关键点**：广播里没有体重。想拿数据必须建立连接、写时间帧、订阅通知。这也是为什么"只监听广播"的方案折腾了很久一无所获。

## 三条被排除的错误路径

| 假设 | 为什么错 | 证据 |
| --- | --- | --- |
| 这是小米生态链秤，走 MiBeacon / FE95，需要 bindkey 解密 | 用户确认从没绑过米家，秤是阿里 × 沃莱联名。曾在同一环境里扫到另一台 `Mijia Scale S400` 的 FE95 广播（`10 59 d9 30 ...`，productId `0x30D9`），是**别人的秤**，与本任务无关 | 广播里没有 `0xFC50` 或阿福登记的 productId；手机蓝牙栈里该小米设备从未被任何 App 连接 |
| 走阿福自研的 `0000FC50` 服务 / AFU 短帧长帧协议 | APK 里确实有这套自研栈（`AFUWeightScaleShortFrameWorker` / `LongFrameWorker`，特征值 `af000002`～`af000006`），但它服务的是另一类 AFU 设备；这台联名秤由 icomon SDK 接管 | `ICBleHandler.java:1702` 只放行 `AFU-WL*` 名字，走 `0000FFB0`；FC50 的 service data 从未在本秤广播里出现 |
| 体重秤的数据在广播里，或 App 把数据写进手机本地数据库 / Health Connect | 广播 7 字节里只有协议标识；App 的外部数据目录里没有任何 `.db` / `.sqlite` / `.json`；手机未 root，`run-as` 报 `package not debuggable`，私有目录读不到 | `adb shell` 目录遍历、`dumpsys` provider 列举、bugreport 检索 |

**教训**：环境里同时能扫到好几台秤，先按「广播名 + 服务 UUID + 用户说的品牌」三要素锁定目标，再动手逆向，否则会围着别人的设备转一整晚。

## 关键发现清单

- **不是小米、不是配对、不是 Wi-Fi**：BLE 明文连接，App 后台自动连，用户看不到"配对"这一步。
- **两层 SDK 并存**：`cn.icomon.icdevicemanager`（沃莱/伊康，管这台秤）与 `com.afu.afudevicemanager` + `aijk_hardware_sdk`（阿福自研 FC50 栈）；两者都打进同一个 APK。
- **Worker 路由**：广播里的 `deviceSubType` 决定用哪个 Worker；`7 / 9 / 10 → ICWeightScale27Worker`，`8 / 11 / 12 → ICWeightScaleV3Worker`。这台是 7。
- **20 字节定长帧**，校验和是 `sum(b[2..18])` 的低 5 位；客户端写出去的帧用全 8 位也能过（256 是 32 的倍数）。
- **体脂不在客户端**：`ICAlgorithmManager.calc(...)` 直接 `return iCWeightData;`，上报字段只有 `weightKg / weightLb / algType / imps`。所以本地要自己建模型。
- **12 项指标只有一个自由变量**：去脂体重 FFM。体水分、蛋白、肌肉、骨骼肌、体脂率、BMR 全是 FFM 的固定比例或线性式，与 App 显示值逐项吻合。
- **BLE 是 1:1**：电脑占着连接时手机 App 收不到这次数据，反之亦然。这是后面所有工具设计成"待机不连接、按需连一次、测完立刻断"的原因。
- **"秤坏了"其实是配置位**：某次之后秤只报体重、不测阻抗、`0xD6` 的 adcs 恒为 `[0, 0]`。不是硬件故障，是 App 连接时把用户信息帧里的 `fun_open_imp` 写成了 0；把用户信息帧（`fun_open_imp = 1` + 身高 / 年龄 / 性别）写回去，阻抗立刻恢复。**不要重置秤**，重置会清掉配对信息。

## 最终可复现链路

1. 编译 Swift CLI，塞进带 `NSBluetoothAlwaysUsageDescription` 的 `.app` 并 ad-hoc 签名（否则 macOS 直接 SIGABRT，见 `05-tooling.md`）。
2. 踩一下秤唤醒；扫描 `AFU-WL*`，连接。
3. `discoverServices` → `FFB0` → 订阅 `FFB2` → 写时间帧（`0xAC, devType, 0x08, time(int32 LE), utc/900, …`）。
4. 收 `0xD5`（`state = bit31` 为锁定）、等 `0xD6`（两路 adc → Ω）、`0xD8` 收到即回 `history-ack(216)`。
5. `FFM = k·H²/Z_avg` 算出体成分；落盘；断开连接。

细节见 `02-protocol.md`，逐字节样本见 `samples/frames.md`。

## 第三个问题的答案：做成了什么

- **`ScaleBar`**（独立私有仓库）：macOS 菜单栏 App。待机只被动扫描，不抢手机 App；点「接收数据」才连一次，测完自动断开。面板显示 14 项本地算出的身体指标、体重 / 体脂趋势图、身体成分构成条，支持 1 周～全部的时间区间、称重记录多选删除、CSV / JSON 导出。数据存进应用自己管理的 SQLite（`measurements` / `frames` / `settings` 三张表），原始 BLE 帧全部保留，方便以后换算法重算。
- **项目内 skill**（`.agents/skills/afu-wl-scale/`）：给后续 agent 用的速查手册，同样是脱敏版。

有意思的延伸（未做）：把 `frames` 里的原始帧拿去拟合更好的个体化 k；多人识别（按阻抗 + 体重聚类）；把体重曲线接到 Home Assistant / 快捷指令；用「离线历史帧」做无手机时的补采。
