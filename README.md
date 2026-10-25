# FkDormLockADs · 宿舍蓝牙门锁一键开锁

> 名字取自「去他 X 的宿舍门锁广告」。功能上就是一把没有广告的备用钥匙。

把我宿舍那把智能门锁的蓝牙协议还原出来，用三个平台各自实现了**一键开锁**：
安卓原生 App、iOS 原生 App、以及一个不装任何软件就能用的网页版。

打开软件 → 自动连上门锁 → 1～3 秒后门开。没有开屏广告，不用点进小程序，不用等 H5 加载。

> ⚠️ **仅供学习蓝牙协议与安全研究使用。请只对自己有权使用的门锁操作，详见 [DISCLAIMER.md](DISCLAIMER.md)。**

---

## 目录

- [它是怎么工作的](#它是怎么工作的)
- [三个客户端对比](#三个客户端对比)
- [先搞清楚两个参数](#先搞清楚两个参数)
- [怎么拿到自己的 activationKey](#怎么拿到自己的-activationkey)
- [快速开始](#快速开始)
  - [网页版（最快，5 分钟）](#网页版最快5-分钟)
  - [安卓 App](#安卓-app)
  - [iOS App](#ios-app)
- [NFC 一碰开锁](NFC.md)
- [仓库结构](#仓库结构)
- [协议速查](#协议速查)
- [FAQ](#faq)
- [已知限制](#已知限制)
- [许可](#许可)

---

## 它是怎么工作的

门锁用的是一颗蓝牙 SoC，跟手机之间走 BLE GATT 自定义服务。官方 App 的流程是：

```
H5 页面(CDN) → 前端桥 → 原生 BLE 控制层 → BLE GATT → 门锁
```

H5 只负责 UI，真正开锁是原生层做的：原生层拿到 `macAddress` 和 `activationKey`，走四步握手下发一条加密指令，锁里的电机推开离合，门就开了。

这个仓库把**原生层那一段**重新写了一遍，直接把 H5 和官方 App 整个跳过去。

四步握手（细节见 [PROTOCOL.md](PROTOCOL.md)）：

```
① 请求随机数   55 AA FF 0D 00 00 0B
                 ← 锁返回 16 字节随机数 R
② 算会话密钥   sessionKey = R XOR activationKey
③ 建立加密链路 55 AA FF 13 00 00 11
                 ← 锁返回 AES(sessionKey, FF1300010012…)   ← 用它验证"这是不是我的锁"
④ 开锁         55 AA 00 10 + AES(sessionKey, FF0B0000090…) + 校验
                 ← 锁返回 AES(sessionKey, FF0B0001000A…)   ← 0001 = 成功
```

整个过程 2～3 秒，全程离线，不联网、不经过任何服务器。

## 三个客户端对比

| | 安卓 App | iOS App | 网页版 |
|---|---|---|---|
| 需要装东西 | 装 APK | 装 IPA（要签名） | 不需要 |
| 打开即开锁 | ✅ | ✅ | 手动点一下 |
| 认锁方式 | MAC 精确匹配 | 广播名 + ack 验证 | 广播名 + ack 验证 |
| 抗"隔壁同型号锁" | ✅ 最强 | ⚠️ 靠 ack 兜底 | ⚠️ 靠 ack 兜底 |
| 浏览器要求 | — | Bluefy（Safari 不支持 Web Bluetooth） | Chrome / Edge |
| 难度 | 中 | 高（签名麻烦） | 低 |

**建议**：日常用安卓 App（最稳）。临时用、或者借别人手机开门，用网页版。

## 先搞清楚两个参数

不管用哪个客户端，你都需要两个值：

| 参数 | 长什么样 | 是什么 |
|---|---|---|
| `macAddress` | `AA:BB:CC:DD:EE:FF` | 门锁的蓝牙 MAC |
| `activationKey` | 32 位十六进制，如 `0123456789abcdef0123456789abcdef` | 你这把锁的长期密钥，绑定账号时由云端下发，之后一直不变 |

**这两个值在仓库里全是占位符，必须换成你自己的。** 代码里搜 `AA:BB:CC:DD:EE:FF` 和 `00000000000000000000000000000000` 就能找到所有要改的地方。

> `activationKey` 相当于你家钥匙。别发到群里、别提交到公开仓库。本仓库作者的那份已经删干净了。

## 怎么拿到自己的 activationKey

官方 App 每次开锁都会把参数打到 logcat 里 —— 这是最省事的入口，**不需要 root，不需要抓包，不需要证书**：

```bash
# 1. 手机连电脑，开 USB 调试
adb devices

# 2. 清空日志，然后在手机上用官方 App 开一次锁
adb logcat -c
#    ……去 App 里点一次开锁……

# 3. 抓出来
adb logcat -d | grep -i "VocLock"
```

会看到类似这样两行：

```
D/VocLockHelperV2 : unlock: macAddress: AA:BB:CC:DD:EE:FF activationKey: 0123456789abcdef0123456789abcdef
```

`macAddress` 和 `activationKey` 两个值就是你要的。（日志 TAG 里那个类名是 App 自己的，不同版本可能不一样；认 `unlock:` 那一行就行。）

<details>
<summary>没装 adb / 抓不到怎么办</summary>

- **没装 adb**：去 [platform-tools](https://developer.android.com/studio/releases/platform-tools) 下压缩包，解压后在该目录开命令行。
- **`grep` 没结果**：先确认手机已授权 USB 调试；有的机型日志级别被压了，试 `adb logcat -d -v brief | findstr VocLock`（Windows）。
- **一点日志都没有**：官方 App 可能换了日志 TAG。改用下面两条兜底：
  - 找 `BluetoothGatt` 相关日志：`adb logcat -d | grep -i "onCharacteristicWrite"`
  - 或者看 App 私有目录（需要 root）：`/data/data/<包名>/shared_prefs/`
- **完全不想折腾**：网页版和 App 都支持在界面里手填这两个值，只要你能从别处问到。
</details>

## 快速开始

### 网页版（最快，5 分钟）

网页版用 Web Bluetooth，浏览器直接跟门锁说话。**iOS 的 Safari 不支持，安卓/iOS 都要用支持 Web Bluetooth 的浏览器**（安卓 Chrome/Edge；iOS 用 Bluefy）。

Web Bluetooth 有个硬性要求：**页面必须是 HTTPS**（`localhost` 除外）。所以本地要起一个带证书的 HTTPS 服务。

```bash
cd web
python serve.py          # 首次运行会自动生成自签证书
```

然后手机浏览器打开 `https://<你电脑的局域网IP>:8443/`。
自签证书会报警告，点「高级 → 继续访问」即可。

第一次点开锁 → 浏览器弹出设备列表 → 找到名字带 `TmallLock` 的那一项选中。
之后浏览器会记住这台设备，再点就不用选了。

> **注意**：宿舍楼里同型号的锁可能不止一把，名字一样。网页版会拿建链 ack 校验，如果连错锁会提示「ack 不匹配」并让你重选。

### 安卓 App

**改参数** → 编译 → 装。

```bash
cd android
# 改 app/src/main/java/com/dorm/lock/MainActivity.java 里的 TARGET_MAC 和 ACTIVATION_KEY
echo "sdk.dir=/path/to/Android/Sdk" > local.properties
./gradlew assembleDebug                 # Windows: gradlew.bat assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

需要 JDK 17 + Android SDK（`compileSdk 34`）。仓库自带 Gradle wrapper，第一次跑会下载 Gradle 8.7。不想配环境就用 Android Studio 打开 `android/` 直接 Run。

App 的行为：点图标 → 授权蓝牙 → 自动直连门锁 → 开锁 → 震动 + 显示「已开锁」。失败会自动重试，再失败才回退到扫描。

### iOS App

iOS 这边卡的不是技术，是**签名**。苹果不允许装未签名 App，所以必须过一道签名。

**第一步：编出未签名 IPA**

本仓库自带 GitHub Actions，推到 GitHub 后自动编（`.github/workflows/ios.yml`）。编完在 Actions 页面下载 artifact `DormLock-unsigned-ipa`。

有 Mac 的话本地也能编：

```bash
cd ios
brew install xcodegen
xcodegen generate
# 然后用 Xcode 打开 DormLock.xcodeproj，选自己设备直接 Run
```

**第二步：签名安装**

| 方案 | 有效期 | 说明 |
|---|---|---|
| **Sideloadly** | 7 天 | Windows/Mac 都行，用免费 Apple ID 签。最简单 |
| **AltStore** | 7 天，自动续签 | 需要一台常开的电脑或树莓派 |
| **SideStore** | 7 天，手机上自动续 | 不用电脑，配置略麻烦 |
| **TrollStore** | 永久 | 只支持 iOS 14.0–16.6.1 / 17.0，装完一劳永逸 |
| **开发者账号** | 1 年 | $99/年，省心 |

Sideloadly 流程：装 [Sideloadly](https://sideloadly.io/) → 插上 iPhone → 拖入 IPA → 填 Apple ID → Start。
装完要去 **设置 → 通用 → VPN与设备管理** 信任一下开发者证书；iOS 16 以上还要在 **设置 → 隐私与安全性 → 开发者模式** 打开并重启。

> 免费 Apple ID 签的 App 7 天过期，过期后重签一次即可，数据不会丢。

iOS 版第一次运行会扫附近所有蓝牙设备，逐个连上去用 ack 验证，找到自己的锁后记住它。所以第一次可能要等十几秒。

## 仓库结构

```
.
├── android/                安卓原生工程（Java，无第三方依赖）
│   └── app/src/main/java/com/dorm/lock/MainActivity.java   ← 全部逻辑在这一个文件
├── ios/                    iOS 原生工程（SwiftUI + CoreBluetooth）
│   ├── Sources/BLEManager.swift      蓝牙状态机
│   ├── Sources/ContentView.swift     界面
│   └── project.yml                   XcodeGen 配置
├── web/                    网页版（纯静态，无框架）
│   ├── index.html          安卓/桌面版
│   ├── ios.html            Bluefy 版
│   └── serve.py            本地 HTTPS 服务
├── .github/workflows/      自动编译未签名 IPA
├── PROTOCOL.md             协议逆向笔记（帧格式、命令表、时序）
└── DISCLAIMER.md           免责声明
└── CONTRIBUTING.md         Issue 规则与维护红线
```

## 协议速查

完整版看 [PROTOCOL.md](PROTOCOL.md)，这里是速查卡。

**服务 UUID**：`00002760-08c2-11e1-9073-0e8ac72e1001`

**帧格式**

| 类型 | 结构 |
|---|---|
| 明文命令 | `55 AA FF <cmd> 00 00 <chk>` |
| 加密帧 | `55 AA 00 10 <16字节密文> <chk>` |

`chk` = 前面所有字节累加和的低 8 位。

**四条关键帧**

| 用途 | 内容 |
|---|---|
| 请求随机数 | `55AAFF0D00000B` |
| 建立加密链路 | `55AAFF13000011` |
| 开锁（明文载荷） | `FF0B0000090000000000000000000000` |
| 开锁成功响应 | `FF0B0001000A00000000000000000000` |

**密钥**：`sessionKey = randomNumber XOR activationKey`（都是 16 字节）

**加密**：AES-128-ECB，NoPadding

**两个必踩的坑**

1. **分包**：开锁帧 21 字节，超过 BLE 默认 MTU 23 的 20 字节载荷上限，必须拆成 `20 + 1` 两次写。
2. **时序**：建链 ack 回来后要等约 180ms 再发开锁帧；等太久（>1s）锁会超时，等太短分包没落完。

## FAQ

**Q：需要门锁支持 NFC 吗？/ 学校没开 NFC 怎么办？**
A：不需要。这条链路跟 NFC 完全无关，是纯蓝牙。网上买的 NFC 贴片只是「碰一下打开一个网址/App」的快捷方式，贴片和锁之间零通信。锁面板上那块 "NFC 区域" 通常是给校园卡用的读卡器，手机贴上去不会有任何反应——详细诊断和三条替代路线见 [NFC.md](NFC.md)。

**Q：一定要联网吗？**
A：不要。握手全程在手机和锁之间完成，飞行模式也能开。

**Q：换了手机还能用吗？**
A：能。`activationKey` 是绑在你的账号和这把锁上的，跟手机无关。

**Q：activationKey 会变吗？**
A：正常不会，它是长期凭证。但如果宿管在后台把你从房间移除、或者锁被恢复出厂设置，就需要重新绑一次、重新抓一次。

**Q：隔壁宿舍也是同型号的锁，会不会开错？**
A：不会。三端都做了 ack 校验 —— 只有用你这把锁的 `activationKey` 才能把锁返回的密文解开成合法的 `FF13…`，别的锁解出来是乱码。安卓版更是直接用 MAC 精确匹配。

**Q：锁没电了会怎样？**
A：这是电子离合锁，断电状态下电机无法动作，只能靠机械钥匙或应急电源。本仓库不涉及任何破解锁体的内容。

**Q：能远程开锁吗（人在外面）？**
A：不能。BLE 有效距离大约 10 米。要远程得自己在门口放一台常开的设备做中继，本仓库不含这个。

**Q：为什么不直接 hook 官方 App？**
A：可以，但没必要。App 有壳有混淆，hook 还得处理 frida 注入、证书固定一堆事；而协议本身是明文的，日志里全有。

## 使用边界（请务必读完）

这个仓库公开的是**协议本身和你自己设备的控制方法**，不含任何真实密钥，也不含任何获取他人密钥的手段。别人克隆了这份代码，面对一把陌生的锁，什么都做不了。

**能用的范围只有一条线：这把锁是你有权使用的那一把。**

- 你自己宿舍/房间的门锁 → 可以
- 你已获得所有者明确授权的设备 → 可以
- 别人家的门锁、你租住但管理方不给你开的房间、学校不让你改的门禁 → **不行**

关于「逆向本身合不合法」「开源会不会出问题」，以及各类灰色请求的处理方式，写在 [DISCLAIMER.md](DISCLAIMER.md) 和 [CONTRIBUTING.md](CONTRIBUTING.md) 里，这里不重复。

一句话：**这是给自己家门配的备用钥匙，不是万能钥匙。** 配错门，后果自己承担。

## 已知限制

- 只验证过**高校宿舍里常见的这一套**门锁（服务 UUID `00002760-…-1001`），其他型号不保证。
- iOS 拿不到 BLE 的真实 MAC，只能用广播名 + ack 兜底，第一次配对可能要多试几次。
- 网页版在部分安卓机型上需要先打开系统定位开关（Web Bluetooth 的扫描依赖它）。
- 免费签名的 iOS App 7 天过期。

## 许可

[MIT](LICENSE)。随便用、随便改，出事自己担。

---

如果这个仓库帮你少看了几十次开屏广告，点个 ⭐ 就行。
