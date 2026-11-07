# 06 · 调研时间线与失败假设

按"当时相信什么 → 为什么被推翻"来记，比按流水账记更有用。所有测量数值都不写进这份文档，示例一律为合成值。

## 阶段一：环境（11-04 夜）

| 做了什么 | 结果 |
| --- | --- |
| 找机器上的 adb | 找到三个，其中 GUI 工具自带的那个带沙盒 entitlements，直接跑 `Trace/BPT trap: 5`。改装 `brew install --cask android-platform-tools` |
| 确认 App 与手机 | `com.antgroup.aijk.android`，Android 17；`run-as` 不可用、HCI 日志目录无权限、`btsnoop_hci.log` 拿不到 |
| 取 APK | 110 MB，13 个 dex；`strings` 里既看到 `AFUWeightScale*Worker`（阿福自研 FC50 栈）也看到 `cn.icomon.icdevicemanager`（伊康/沃莱 SDK） |

**当时的误判**：以为目标秤走小米 MiBeacon / 标准 Weight Scale 服务。后来发现 `0000181b` / `00002a9c` 在 strings 里零命中，但还没意识到"旁边那台小米秤根本不是目标"。

## 阶段二：第一次上秤取证（11-05 凌晨）

- 用户踩秤并同步到手机；Mac 侧扫到一台 `Mijia Scale S400`，广播 `sdata(FE95) = 10 59 d9 30 <counter> …`，FrameControl `0x5910`、**没有 Object 字段**，30 分钟内除 counter 外字节不变。
- 用 Swift CLI 连上这台 S400，GATT 有 `00008000-0065-6C62-2E74-6F696D2E696D`（小米私有）与 FE95 服务，读 `FE95/0004` 得到固件版本 ASCII；订阅所有 notify 后**零字节**。
- `adb bugreport` 解出 158 MB 系统日志，`GATT Client Map` 证明上秤那一刻确实是阿福在注册 GATT client，但连的对端地址不是那台小米秤。

**结论（当时）**：广播里没有体重，需要连接 + 握手；怀疑要 bindkey。查资料发现开源社区对 S400 的连接模式也卡在 auth v2 需要小米后台签名 —— 这条路本来就是死胡同，**因为设备认错了**。

## 阶段三：方向纠正（11-05 上午）

用户一句"没有绑过米家，它根本就不是小米生态里的产品，是阿里的，往手机上的蚂蚁阿福 APP 里传过数据"把方向掰回来。

- 装 JDK（清华镜像）+ jadx 1.5.6，全量反编译 5 万个类。
- 找出两套 BLE 栈：icomon (`FFB0`) 与阿福自研 (`FC50`)；把 FC50 的广播判据、短帧/长帧、凭证握手都逆了一遍。
- 做 `FC50` / `FE95` / `AFU-WL` 三种候选自动连接的探针，跑了 45 秒全量广播扫描，周边 38 台设备里**一个 FC50 都没有**。

**教训**：用户随口的一句产品归属，比一百个反编译类更值钱。逆向之前先问清楚"这到底是哪台设备"。

## 阶段四：锁定真秤、打通协议（11-05 晚）

用户补充："秤是蚂蚁阿福和沃莱科技合作的，货号 A1，型号 FG2508WB"，并把秤放到电脑旁、重新踩了一次。

- 300 秒全量扫描终于看到 `AFU-WL-TZ-A1`，`svc=[FFB0,1530]`、`sdata(27AC)` —— 沃莱 = APK 里 `@MpaasClassInfo(...product_wellandbodyfatscale, Product="阿福三方SDK")` 那个模块。
- 从 `ICBleHandler.java:1702` 的 `name.startsWith("AFU-WL")` 到 `ICWorkerManager.getNormalWorkerNameByScanModel` 的 deviceSubType 7 → `ICWeightScale27Worker`，一条链打通。
- 第一次用 `retrievePeripherals(withIdentifiers:)` 直连成功，枚举 GATT、订阅 `FFB2`、写时间帧，**秤立刻开始每 120 ms 推一帧**。
- 解 `0xD5` 时先按小端读 `core`，算出荒谬的体重；回去读 `ICStreamBuffer.ReadInt()` 才发现 `SetLittleEndian(true)` 下不交换字节，**实际是大端**。
- 校验和一开始按整字节和比对、全部判错；真实规则是 `sum(b[2..18]) & 0x1F`。

## 阶段五：体脂、历史帧与"秤是不是坏了"（11-05 深夜）

| 现象 | 排查 | 结论 |
| --- | --- | --- |
| 体重有了，但 `0xD6` 的 adcs 恒为 `[0,0]`，秤屏也不再闪后面的体脂数据 | 先怀疑脚没踩电极 / 穿袜子；核对 `dianji`、`supportFuns`、电量位都和正常那次一样；再看时间线，中间 App 连过秤 5 次 | **不是硬件故障**。App 连接时写用户信息帧，把 `fun_open_imp` 关掉了。写回 `flags \|= 1` + 正确身高/年龄/性别，下一测立刻恢复两路非零阻抗。用户问"要不要重置秤" → 不要，重置会清配对 |
| 同一条 `0xD8` 每 1.5 秒重发，看起来像很多条离线记录 | 数时间戳，内容完全一致 | 我们的工具从不回 ACK。`ICWeightScale27Worker` 里 `sendReplyCMD(216)` 是必须的，补上后秤不再重发、正常断开 |
| 手机 App 没收到某次数据 | 看 App 的 GATT Client Map，那段时间没有会话 | **BLE 1:1**：电脑占着连接，秤认为数据已投递。之后所有工具改成"待机只扫描、按需连一次、测完立刻断" |
| 体脂率从哪来 | `ICAlgorithmManager.calc()` 是空壳；上报字段只有 `weightKg / weightLb / algType / imps` | 服务端算的。于是自己用 `FFM = k·H²/Z_avg` 拟合，12 项指标逐项对上 |

## 阶段六：产品化（11-06）

- 单文件 `scalebar.swift` 原型 → 独立 SwiftPM 仓库 `jovix0101/scalebar`（`ScaleBarCore` 纯逻辑 + `ScaleBar` AppKit + 单元测试 + `build.sh` + GitHub Actions 出 universal dmg）。
- 面板从"16 个数字挤在左上角"迭代到卡片式双列布局；踩过的 AppKit 坑：`NSStackView` 子视图约束 `equalTo: stack.widthAnchor` 导致 `loadView` 死锁、`Pill` 隐藏时 stack 折叠列造成纵向错位、`_ = panel.view` 没提前调用导致 outlet 为 nil 崩溃。
- 加了趋势图、体成分条、区间切换、资料（出生年份自动推年龄）、称重记录删除、中文指标名与 ⓘ 提示。

## 阶段七：整理与交付（11-07）

- 存储从"散落的 CSV / jsonl / json"改成应用自管的 SQLite（三张表），去掉「数据目录」按钮改成「导出」，老文件首次启动自动迁移后删除。
- 记录窗口与指标区排版重做（改 `NSGridView` 根治列错位）。
- 生成应用图标、用**合成数据**截一组 README 截图、修正提交身份、整理本调研档案并写文档。

## 一句话教训清单

1. 先确认设备身份（名字 + 服务 UUID + 用户说的品牌），再逆向。
2. 广播里通常没有有效载荷；别在被动嗅探上死磕，但也要先证明它确实没有。
3. macOS 上 CoreBluetooth 必须有 Info.plist usage strings + 签名 + `open -n`；Swift delegate 的 `error:` 标签写错会静默失败。
4. 端序、校验和取模、单位分度值 —— 三个最容易让"看起来对"的数据变成垃圾的地方。
5. 设备行为突然变化，先看自己 / App 最近写了什么配置位，别先怀疑硬件。
6. BLE 是 1:1，工具要"不抢连接"是设计约束，不是优化项。
7. 把"服务端算的"和"本地能算的"分清楚，别去 APK 里找一个不存在的公式。
8. 任何要写进公开 / 私有仓库的东西，脱敏要在生成样本时做，不是事后删几行。
