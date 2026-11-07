# 06 · 验证记录

按模块记录每条结论是怎么验证的。示例一律为合成值。

## 环境与素材

| 项目 | 内容 |
| --- | --- |
| 手机 / App | Android 17 / `com.antgroup.aijk.android` 1.1.78.2100 |
| 电脑 | macOS，`brew install --cask android-platform-tools` 提供 adb |
| APK | 110 MB，13 个 dex；JDK 21 + jadx 1.5.6 全量反编译约 5 万个类 |
| 手机侧日志 | `adb bugreport` 解出 158 MB 系统日志，`DUMP OF SERVICE bluetooth_manager` 段给出 `GATT Client Map` 与 `BluetoothRemoteDevices` |
| 探测工具 | Swift / CoreBluetooth CLI，装进带 `NSBluetoothAlwaysUsageDescription` 的 `.app` 后 ad-hoc 签名运行 |

## 设备识别

- 广播名 `AFU-WL-TZ-A1`，service `0000FFB0`（另有 `1530` Nordic DFU），`sdata(27AC)` 为 7 字节协议标识。
- `ICBleHandler.java:1702` 只放行 `AFU-WL` 前缀；广播字节解析出 `deviceSubType = 7` → `ICWorkerManager.java:768-777` 路由到 `ICWeightScale27Worker`。
- APK 里的 `@MpaasClassInfo(...product_wellandbodyfatscale, Product="阿福三方SDK")` 对应沃莱模块。

## 链路验证

| 结论 | 怎么验证的 |
| --- | --- |
| 广播里没有体重 | 被动扫广播的 7 字节 service data 只有协议标识、版本、状态 |
| 必须连接 + 写时间帧 | 订阅 `FFB2` 后写入 `operate_type=8` 的时间帧，秤立刻以约 120 ms 间隔推送 20 字节定长帧 |
| 帧类型 | `0xD5` 体重（含 `state` 锁定位）、`0xD6` 阻抗（锁定后 2～3 秒）、`0xD8` 离线历史 |
| 历史帧要确认 | 回 `history-ack(216)` 后秤不再重发，并正常断开 |
| 端序 | `ICStreamBuffer.ReadInt()` 在 `SetLittleEndian(true)` 下不交换字节，`core` 实际是大端 |
| 校验和 | `sum(b[2..18]) & 0x1F`；写出去的帧用全 8 位也通过（256 是 32 的倍数） |
| 阻抗测量开关 | 用户信息帧里的 `fun_open_imp` 位；写回带该位的帧后，`0xD6` 恢复两路非零 adc |

## 手机侧

- `GATT Client Map` 的 `AppRecord` 确认上秤那一刻是阿福在注册 GATT client，会话持续 7～70 秒后注销。
- App 私有目录、`icomon` / AFU SDK 日志文件、`btsnoop_hci.log` 均不可读；logcat 里没有秤的数据帧。服务端算出的指标只能从 App 界面取证。
- `ICAlgorithmManager.calc()` 是空壳，上报字段只有 `weightKg / weightLb / algType / imps` → 体脂在服务端算。
- 本地用 `FFM = k · H² / Z_avg` 复现 12 项指标，与 App 显示值逐项吻合。

## 产品化（当前状态）

- 独立 SwiftPM 仓库 `jovix0101/scalebar`：`ScaleBarCore` 纯逻辑 + `ScaleBar` AppKit + 单元测试 + `build.sh` + GitHub Actions 出 universal dmg。
- 菜单栏面板：14 项本地算出的指标、体重与体脂趋势图、体成分条、1 周～全部的时间区间、称重记录删除、CSV / JSON 导出、合成数据截图与应用图标。
- 数据存进应用自管的 SQLite，三张表：`measurements` / `frames` / `settings`。

## 可复用的方法论

1. 先按广播名 + 服务 UUID 锁定设备，再逆向。
2. 广播不含有效载荷时，转为连接 + 握手。
3. macOS 上 CoreBluetooth 需要 Info.plist usage strings + 签名 + `open -n`；Swift delegate 的 `error:` 标签写错会静默失败。
4. 端序、校验和取模、单位分度值最容易让"看起来对"的数据变成垃圾。
5. 设备行为突然变化，先看最近写了什么配置位。
6. BLE 是 1:1，工具要"不抢连接"是设计约束。
7. 把"服务端算的"和"本地能算的"分清楚。
8. 脱敏要在生成样本时做，不是事后删几行。
