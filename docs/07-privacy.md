# 07 · 脱敏说明与未入库素材

## 原则

这个仓库是**调研资料**，不是数据备份。凡是能指向某个具体的人、某台具体设备、或某次真实测量的东西，一律不入库；协议常量、产品型号、代码方法名与行号属于产品或代码事实，保留。

**假数据要"自洽地假"**：不是把数字随便改掉，而是生成一套内部一致的合成人设 + 合成帧 + 合成记录，让文档里的示例、截图、测试能互相验证。

## 合成人设（全仓库统一）

| 字段 | 值 |
| --- | --- |
| 身高 | 175 cm |
| 出生年份 | 1984（年龄由当前年份自动推算） |
| 性别 | 男 |
| 体重 | 78.40 kg（示例基准），趋势样本 78.3～78.9 kg |
| 两路阻抗 | 505～515 Ω |
| 标定系数 | `k = 0.9788`，`k·H² ≈ 29976` |
| 演示记录数 | 9 次 |

由这套人设算出的体脂率约 24.6%、BMI 25.6、BMR 1647 kcal，全部与 `04-body-model.md` 的演算一致。合成帧见 [`../samples/frames.md`](../samples/frames.md)。

## 入库 / 不入库

| 入库 ✅ | 原因 |
| --- | --- |
| `README.md`、`docs/*.md` | 方法与结论，数值全部合成 |
| `samples/frames.md`、`samples/decode.py` | 合成帧与可运行校验脚本 |
| `src/*.swift`、`src/scan.py` | 脱敏后的工具；个人资料走 `AFU_*` 环境变量、设备 UUID 为占位 `11111111-2222-3333-4444-555555555555` |
| `.agents/skills/afu-wl-scale/` | 项目内 agent skill，同一套协议速查；同样是合成值、env 驱动 |
| 产品型号 `A1` / `FG2508WB` / `FG2313UWB-D`、厂商 `ICOMON`、固件版本、协议常量、SDK 类名与行号 | 产品或代码事实，且对复现必要 |

| 不入库 🚫 | 原因 | 本机位置（`.gitignore` 已排除） |
| --- | --- | --- |
| `apk/afu.apk` + 解出的 13 个 dex | 第三方 APK，110 MB，有版权问题 | `/apk/` |
| `decomp/afu/sources/`（约 5 万类） | 反编译产物，773 MB，版权 | `/decomp/` |
| `bug/bugreport*.zip` 与解压日志 | 158 MB 整机日志，含设备标识、账号、网络信息、姓名 | `/bug/` |
| `tools/jdk-*` | 335 MB 本地 JDK | `/tools/` |
| 各 `.app/` 宿主、`blescan` 二进制、`.venv*` | 构建产物 | `*.app/`、`/.venv*`、`/blescan` |
| `captures/*.txt`（真实 BLE 抓包） | **含每次真实体重、阻抗、设备 UUID** | `/captures/` |
| `shots/*.png`（手机截图） | 含姓名、体重、体脂率、App 里的对话内容 | `/shots/` |
| 根目录的 `afuscale*.swift`、`scalebar.swift` | 写死了真实设备 UUID 与个人资料（`U_HEIGHT` / `U_AGE` / `U_WEIGHT`） | `/*.swift`、`/*.py`；脱敏版在 `src/` |

`src/` 里保留的是重新整理过的版本：`afuscale.swift` 的所有人设常量都从 `AFU_H` / `AFU_AGE` / `AFU_SEX` / `AFU_WEIGHT` / `AFU_UUID` 读取，默认值是合成人设与占位 UUID。

## 真实数据还在哪儿

- 产品化 App 的数据：`~/Library/Application Support/ScaleBar/scaledata.sqlite`（SQLite，应用自管；另有 `scalebar.log`）。它**不在本仓库里**，也不随仓库分发。
- 本机的原始抓包 / 截图 / bugreport / APK 仍在原目录，被 `.gitignore` 排除，方便以后复核，但不会 `push` 出去。

## 已经做过的清理

- 早期曾把 skill 装到全局并软链到其他 agent（`~/.pi/agent/skills/`、`~/.codex/skills/`），已按用户要求**全部删除**，只保留项目内的 `.agents/skills/afu-wl-scale/`（pi 会自动发现项目级 skill）。
- 公开 / 私有仓库的 README 截图用 `SCALEBAR_DB=/tmp/demo_scalebar.sqlite` 造的临时演示库生成，生成前把真实数据目录整体挪走、生成后恢复；截图里不含任何真实记录。
- 两个仓库都不包含第三方 APK、整机 bugreport、设备 MAC / UUID、姓名、真实体重曲线。

## 自己造一份演示数据

```bash
# 1) 用合成人设生成一个临时 SQLite，喂给 ScaleBar 做演示截图
SCALEBAR_DB=/tmp/demo.sqlite SCALEBAR_AUTOPOP=1 \
SCALEBAR_SNAPSHOT=/tmp/panel.png SCALEBAR_AUTOQUIT=1 \
open -n ./build/ScaleBar.app

# 2) 合成帧的校验和与解析
python3 samples/decode.py

# 3) 用假人设跑参考 CLI（不会连真秤时也能验证解析逻辑）
AFU_H=175 AFU_AGE=42 AFU_WEIGHT=78.40 \
swiftc -O src/afuscale.swift -o /tmp/afuscale_demo
```

## 提醒

- 即使是**私有库**，也不建议上传第三方 APK / 整机 bugreport —— 一旦仓库被 clone 或转让，这些内容很难收回。
- 如果以后要引用真实抓包说明某个现象，请先把帧里的 `weight_g`、时间戳、设备 id 换成合成值，再贴进文档。
- `git log` 里也不要写真实数值（提交信息里出现具体体重 / 体脂率等于把数据写进历史）。
