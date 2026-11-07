# 03 · 蚂蚁阿福 APK 里到底发生了什么

> 反编译产物（`decomp/afu/sources/`，约 5 万个类）**不入库**。本文记录的是类 / 方法 / 行号索引，
> 行号基于 jadx 1.5.6 反编译的 `com.antgroup.aijk.android` 1.1.78.2100。
> 包名、方法名、协议常量属于代码事实；示例数值一律为合成演示值。

## 1. 怎么拿到可读的代码

```bash
# JRE：GitHub 上的 JDK 太慢，走清华 Adoptium 镜像（约 12 MB/s）
curl -sSL -o /tmp/jdk21.tar.gz \
  "https://mirrors.tuna.tsinghua.edu.cn/Adoptium/21/jdk/aarch64/mac/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.13_9.tar.gz"
tar xzf /tmp/jdk21.tar.gz -d tools/
export JAVA_HOME="$PWD/tools/jdk-21.0.13+9/Contents/Home"

# jadx（GitHub release 有时会下到一半被截断，curl -C - 续传）
curl -L -C - -o /tmp/jadx.zip https://github.com/skylot/jadx/releases/download/v1.5.6/jadx-1.5.6.zip
unzip -o /tmp/jadx.zip -d /tmp/jadx_out
/tmp/jadx_out/bin/jadx -d decomp/afu --no-res --show-bad-code -j 8 apk/afu.apk
```

全量反编译约 4 分钟，`finished with errors, count: 427` 可忽略，目标类都出来了。
`androguard` 适合快速列类名，注意 `DEX(path_str)` 会报 `a bytes-like object is required`，要用 `DEX(open(f,'rb').read())`。

## 2. 两套 BLE 栈并存

| | icomon（管这台秤） | 阿福自研 AFU 栈 |
| --- | --- | --- |
| 顶层包 | `cn.icomon.icdevicemanager` | `com.afu.afudevicemanager`、`com.antgroup.aijk.android.aijk_hardware_sdk` |
| 来源标记 | `@MpaasClassInfo(BundleName = "com-antgroup-aijk-android-product_wellandbodyfatscale", Product = "阿福三方SDK")` | 自有代码 |
| 主服务 | `0000FFB0-0000-1000-8000-00805F9B34FB`（`FFB1` 写 / `FFB2` 通知） | `0000FC50-0000-1000-8000-00805F9B34FB`（`af000002`～`af000006`） |
| 秤 Worker | `ICWeightScale27Worker` / `ICWeightScaleV3Worker` | `AFUWeightScaleShortFrameWorker` / `LongFrameWorker` |
| 帧 | 20 字节，`0xD5/D6/D8/DF` | 短帧 / 长帧，带凭证握手、逐帧 ACK |
| 广播识别 | 名字前缀 `AFU-WL` + `27AC` service data | `0xFC50` service data，要求恰好 11 字节且 `b[0]=0xAF, b[1]=0x01` |

**这台联名秤走 icomon**。判断依据不是猜的：广播名是 `AFU-WL*`，服务是 `FFB0`，GATT 里根本没有 FC50；而 `ICBleHandler.java:1702` 只放行 `AFU-WL*`。

顺带把 AFU 自研栈的广播格式也逆了出来（留作以后遇到别的阿福设备时用）：
`aijk_hardware_sdk/k6.java` 的 `static f6 a(s6)` 要求 `bArr[4]` 的 `(b & 0x70)>>4 ∈ {4,5,6}`、`b & 0x0F ∈ 5..8`，`bit7` 决定 Connect / Broadcast 模式；`AFUDeviceManager.java:463/1840` 把 FC50 加进扫描列表；`x8.java:86` 的日志是 `"scan ignored, no valid AFU 0xFC50 service data …"`。

## 3. 扫描 → 识别 → 路由

```
ICBleHandler.java:1702
  if (!name.startsWith("AFU-WL")) return;          // 别的秤直接丢
  ICScanRecord.parse(manfactureData)
  serviceData key 含 "AC" → 反转成 AC 27 + value
  ReadByte() == 0xAC → 校验通过
  bit7      → Connect(0) / Broadcast(1)
  (b&0x70)>>4 → 1 WeightScale / 2 FatScale / 3 Balance / 4 Kitchen / 5 Ruler / 6 Skip
  b & 0x0F  → deviceSubType

ICWorkerManager.java:768-777  getNormalWorkerNameByScanModel
  deviceSubType 7 / 9 / 10  → ICWeightScale27Worker
  deviceSubType 8 / 11 / 12 → ICWeightScaleV3Worker
```

本机 `0x27` → Connect 模式、FatScale、**deviceSubType 7** → 27 协议。
`ICConfigManager` 里还有一张 MiBeacon 产品表，但只登记了一个 `productId = 14623 (0x391F)`；`ICDeviceManager.java:2439-2455` 读 `serviceDatas["FE95"]` 取 productId 后 `getMIDeviceByProductId(...)`，查不到就 `return null`。这解释了为什么旁边那台小米秤（productId `0x30D9`）永远不会被阿福认出来。

## 4. 连接之后 App 写了什么

`ICWeightScale27Worker.onUpdateNotificationState`（约 `:1052-1059`）：

```text
notify 打开成功 → setTime() → updateUserList() → updateInfo() → 上报 Connected 事件
```

| 方法 | 位置 | 内容 |
| --- | --- | --- |
| `setTime()` | `:1274` | `device_type, operate_type=8, time, utc_offset` → `encodeSetting` |
| `updateInfo()` | `:1325` | `if (!isSetUserInfo) { logInfo("no user info"); return; }`；写 `height / weight / age / sex / peopleType / target_weight / unit / fun_open_imp / fun_open_littleweight / fun_open_banlance / fun_open_hr / fun_open_gravity / fun_open_baby_mode`，最后 `encodeData(map, (subType==9｜｜10) ? 3 : 1)` |
| `updateUserList()` | `:1367` | 多用户列表 → `encode(2)` 或 `encode(4)` |
| `sendReplyCMD(int)` | `:1252` | `operate_type=4, reply_cmd=i`，用于确认历史帧（216）与测量结束（214/215） |
| `readSign()` / `readAFUSign()` | `:1204-1246` | `operate_type=9` / `6`，读签名；`model == "FG2313UWB-D"` 时被排除 |

> **重要**：`updateInfo()` 里的 `fun_open_imp` 就是阻抗测量总开关。一次 App 连接把它写成 0 之后，秤只报体重、`0xD6` 的 adcs 恒为 `[0,0]`，秤屏也不再闪体脂 —— 看起来非常像硬件坏了。写回用户信息帧（带 `fun_open_imp=1` 和正确的身高/年龄/性别）就恢复了。**结论：先动协议，别急着重置设备。**

## 5. 体脂公式不在客户端

这是整份调研里最反直觉的一点。

```java
// cn/icomon/icdevicemanager/manager/algorithms/ICBodyFatAlgorithmsImpl.java
reCalcBodyFatWithWeightData(ICWeightData d, ICUserInfo u) {
    return ICAlgorithmManager.calc(u, d);
}

// cn/icomon/icdevicemanager/common/ICAlgorithmManager.java:43-45
public static ICWeightData calc(ICUserInfo u, ICWeightData d) {
    return d;                       // 原样返回，空壳
}
```

`aq/wlbfs/*`（沃莱体脂模块，60+ 个混淆类）只消费 `ICWeightData.impendences` 做 UI 上报，没有公式；APK 里也没有 `libicomon*` / `libwelland*` 的 native 库（只有无关的 `libalgorithm-jni-AQ-AT5.so`、`libvialgorithm.so`）。

上报入口 `aq/wlbfs/f1.java:68`：

```java
HealthIndicatorDTOPB b(long j, double d, double d2, int i, List list)
  indicator = "weight"
  map.put("weightKg" / "weightLb")
  map2.put("algType", String.valueOf(i))     // 本机 41 → WLA41
  map2.put("imps", JSON.toJSONString(list))  // 两路阻抗
```

**只传体重 + 阻抗 + 算法编号，体脂是服务端算的。** 所以要在电脑上离线算，必须自己建模型 —— 这就是 `04-body-model.md`。

## 6. 日志与本地数据在哪

| 想找的东西 | 结论 |
| --- | --- |
| App 私有目录 | `run-as com.antgroup.aijk.android` → `run-as: package not debuggable`；未 root 读不到 `/data/data/…` |
| 外部数据目录 `/sdcard/Android/data/com.antgroup.aijk.android/files` | 只有支付宝多媒体缓存、`nebulaH5App`、`MobileAiX`、emoji、模型文件，**没有 `.db/.sqlite/.json`** —— 体重记录不在本地明文文件里 |
| icomon 日志 | `ICLoggerHandler.java:22`：`BASE_PATH="/icomon/"`、`DISK_CACHE_PATH="/dmlogs"`、`LOG_PATH="/cache"`，写到 `getFilesDir()` 私有目录 + 委托钩子 |
| AFU 自研栈日志 | `AFULoggerHandler.Init(Context)` → `getFilesDir() + "/afu/afublesdklogcache"`，同样私有 |
| logcat | 全 APK 里只有 `com/afu/wearable/sdk/logging/AfuFirmwareFrameLogger.java` 用 `android.util.Log` → **logcat 里不会有秤的数据帧**，别在这儿等 |
| btsnoop / HCI 日志 | `settings put global bluetooth_hci_log 1` 能打开，但 `/data/misc/bluetooth/logs` 非 root 读不到。bugreport 里能拿到 `bluetooth_*.log` 文本日志，但 `btsnoop_hci.log` 不在其中 |
| Health Connect | 手机上装了 `com.android.healthconnect.controller`，但没有对应的 ContentProvider |

**取证路线**（都试过）：`adb bugreport` → 解压出 158 MB 的系统日志 → 在 `DUMP OF SERVICE bluetooth_manager` 段看 `GATT Client Map` 的 `AppRecord`（appName / 起止时间 / reason）与 `BluetoothRemoteDevices` 的 `[Packages]` 归属。靠这个确认了"上秤那一刻确实是阿福在注册 GATT client，而且连的是秤而不是别的设备"。

## 7. 一个容易误判的现场

同一间屋子里能同时扫到两台秤：

- 目标：`AFU-WL-TZ-A1`，`svc=[FFB0,1530]`，`sdata(27AC)`。
- 干扰项：一台 `Mijia Scale S400`，`sdata(FE95) = 10 59 d9 30 <counter> …`，FrameControl `0x5910`、productId `0x30D9`、**无 Object 字段**（广播里没有体重），Frame counter 半小时才从 `08` 变到 `0a`，其余字节不变。

一开始误把 S400 当成目标，围着 MiBeacon / bindkey 查了很久（开源社区对 S400 的连接模式也卡在 auth v2 需要小米后台签名）。后来用户一句"这是阿里的，没绑过米家，数据进蚂蚁阿福"才把方向掰回来。**逆向前先确认设备身份，比读一百个类有用。**
