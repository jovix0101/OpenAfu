# OpenAfu — 蚂蚁阿福体脂秤 BLE 协议调研资料

这是一份**调研档案**，不是产品代码仓库。记录的是：怎么把一台「蚂蚁阿福 × 沃莱科技」联名体脂秤（货号 A1 / 型号 FG2508WB）的体重、阻抗、体成分数据，从手机 App 之外直接读到电脑上，以及这个过程中走过的弯路。

可运行的产品化实现已经独立成仓库：[`jovix0101/scalebar`](https://github.com/jovix0101/scalebar)（macOS 菜单栏 App，SwiftPM + SQLite + CI 出 dmg）。本仓库保留的是**方法、证据、协议规格和可复用的探测工具**。

> ⚠️ **适用性**：以下结论只对这一台联名秤成立（BLE 名前缀 `AFU-WL`、服务 `0000FFB0`、`deviceSubType = 7` → icomon 27 协议）。蚂蚁阿福的其他合作款、其他 icomon 秤、小米生态链秤都不保证适用。验证方法见 [`docs/02-protocol.md`](docs/02-protocol.md) 开头。

## 一句话结论

这台秤**不用配对、不连 Wi-Fi、也不走小米生态**。它在被踩醒后的 2～3 分钟里广播自己的名字，手机 App 后台连上 BLE，通过 `0000FFB0` 服务的 `FFB1`(写) / `FFB2`(通知) 交换 20 字节定长帧：先写时间帧，秤就开始推体重帧 `0xD5`、阻抗帧 `0xD6`、离线历史帧 `0xD8`。体脂率等 12 项指标**不在 App 里算**（客户端算法类是空壳），是 App 把「体重 + 两路阻抗」上传到服务端算的；本地可以用 `FFM = k·H²/Z_avg` 反推出几乎一致的结果。

## 仓库地图

| 路径 | 内容 |
| --- | --- |
| [`docs/01-summary.md`](docs/01-summary.md) | 结论摘要：数据链路、被排除的三条错误路径、最终可复现链路 |
| [`docs/02-protocol.md`](docs/02-protocol.md) | **BLE 协议规格**：广播、GATT 树、20 字节帧格式、校验和、三类数据帧、三种写入帧、会话时序 |
| [`docs/03-app-internals.md`](docs/03-app-internals.md) | 阿福 APK 逆向：两套 SDK、关键类与行号、扫描过滤、Worker 路由、体脂为何在服务端 |
| [`docs/04-body-model.md`](docs/04-body-model.md) | 体成分模型：12 项指标如何由 FFM 一个变量导出、标定方法、误差来源 |
| [`docs/05-tooling.md`](docs/05-tooling.md) | 工具链与踩坑：adb、macOS 蓝牙权限、Swift CoreBluetooth、jadx、bugreport |
| [`docs/06-timeline.md`](docs/06-timeline.md) | 调研时间线、失败假设与教训（含「秤是不是坏了」的排查） |
| [`docs/07-privacy.md`](docs/07-privacy.md) | 脱敏说明：什么入库、什么不入库、合成数据怎么造 |
| [`samples/frames.md`](samples/frames.md) | 合成帧样本与逐字节解析；[`samples/decode.py`](samples/decode.py) 是可跑的校验脚本 |
| [`src/`](src/) | 脱敏后的 Swift / Python 探测工具（扫描、GATT 枚举、抓包、组帧） |
| [`src/README.md`](src/README.md) | 每个工具的用途与运行方式 |
| [`.agents/skills/afu-wl-scale/`](.agents/skills/afu-wl-scale/) | 项目内 agent skill：同一套协议的速查与参考实现 |

## 隐私与脱敏

本仓库**不含任何真实测量数据**：

- 所有示例身高、体重、年龄、体脂率、阻抗都是**合成演示值**（175 cm / 1984 年生 / 男 / 78.40 kg / 阻抗 505～515 Ω）。
- 真实抓包、手机截图、bugreport、APK、反编译产物、设备 UUID / MAC、姓名全部留在本地，由 `.gitignore` 排除。
- 协议常量、产品型号、代码方法名与行号属于产品或代码事实，予以保留。

详见 [`docs/07-privacy.md`](docs/07-privacy.md)。即使仓库是私有的，也不建议把第三方 APK 和整机 bugreport 传上去。

## 三十秒复现（概念版）

```bash
# 1. 编译一个能拿蓝牙权限的 Swift CLI，并放进带 NSBluetoothAlwaysUsageDescription 的 .app
# 2. 踩一下秤把它唤醒（它只在醒来后的短窗口里广播）
# 3. 连接 AFU-WL*，订阅 FFB2，写入时间帧
# 4. 读 0xD5 等体重锁定，再等 2~3 秒读 0xD6 拿两路阻抗
# 5. 断开，让手机 App 继续用（BLE 同时只能有一个中心设备）
```

完整命令、坑和排错见 [`docs/05-tooling.md`](docs/05-tooling.md) 与 [`docs/02-protocol.md`](docs/02-protocol.md)。

## 免责

本项目是对**自有设备**的互操作性研究，用于让自己在电脑上读到自己的称重数据。没有绕过鉴权、没有修改设备固件、没有接入任何服务端接口；所有写入帧都是 App 自己也会发的正常配置（时间 / 用户信息 / 历史确认）。第三方 APK 与其反编译产物不随仓库分发。
