# OpenAfu — 蚂蚁阿福体脂秤 BLE 协议调研资料

「蚂蚁阿福 × 沃莱科技」联名体脂秤（货号 A1 / 型号 FG2508WB）的协议调研档案：广播、GATT、数据帧、写入帧、体成分模型和探测工具。

产品化实现在独立仓库 `jovix0101/ScaleBar`（私有）。

## 结论

秤被踩醒后广播 `AFU-WL*`。App 通过 BLE 服务 `0000FFB0` 的 `FFB1`（写）/ `FFB2`（通知）交换 20 字节定长帧：写入时间帧后，秤推送 `0xD5` 体重、`0xD6` 阻抗、`0xD8` 离线历史帧。体脂等 12 项指标由 App 把体重与两路阻抗上传服务端计算；本地用 `FFM = k · H² / Z_avg` 可以复现。

结论适用于 BLE 名前缀 `AFU-WL`、服务 `0000FFB0`、`deviceSubType = 7`（icomon 27 协议）的这台秤，验证方法见 [`docs/02-protocol.md`](docs/02-protocol.md) 开头。

## 文档

| 路径 | 内容 |
| --- | --- |
| [`docs/01-summary.md`](docs/01-summary.md) | 结论摘要与数据链路 |
| [`docs/02-protocol.md`](docs/02-protocol.md) | **BLE 协议规格**：广播、GATT 树、帧格式、校验和、三类数据帧、三种写入帧、会话时序 |
| [`docs/03-app-internals.md`](docs/03-app-internals.md) | 阿福 APK 逆向：SDK 结构、关键类与行号、扫描过滤、Worker 路由 |
| [`docs/04-body-model.md`](docs/04-body-model.md) | 体成分模型：12 项指标如何由 FFM 导出、标定方法 |
| [`docs/05-tooling.md`](docs/05-tooling.md) | 工具链：adb、macOS 蓝牙权限、CoreBluetooth、jadx |
| [`docs/06-timeline.md`](docs/06-timeline.md) | 调研时间线 |
| [`docs/07-privacy.md`](docs/07-privacy.md) | 脱敏说明 |

## 样本与工具

- [`samples/frames.md`](samples/frames.md) — 合成帧样本与逐字节解析；[`samples/decode.py`](samples/decode.py) 是可运行的校验脚本
- [`src/`](src/) — Swift / Python 探测工具，用法见 [`src/README.md`](src/README.md)
- [`.agents/skills/afu-wl-scale/`](.agents/skills/afu-wl-scale/) — 项目内 agent skill

## 复现

```bash
# 1. 编译带 NSBluetoothAlwaysUsageDescription 的 Swift .app 探测工具
# 2. 踩一下秤唤醒广播
# 3. 连接 AFU-WL*，订阅 FFB2，写入时间帧
# 4. 读 0xD5 等体重锁定，再读 0xD6 拿两路阻抗
# 5. 断开（BLE 同时只能有一个中心设备）
```

命令与排错见 [`docs/05-tooling.md`](docs/05-tooling.md) 和 [`docs/02-protocol.md`](docs/02-protocol.md)。

## 数据说明

仓库只使用合成演示数据（175 cm / 1984 年生 / 男 / 78.40 kg / 阻抗 505～515 Ω）。真实抓包、手机截图、设备标识、APK 与反编译产物都留在本地，不入库。详见 [`docs/07-privacy.md`](docs/07-privacy.md)。
