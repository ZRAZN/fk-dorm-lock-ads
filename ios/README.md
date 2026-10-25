# iOS 版

SwiftUI + CoreBluetooth，无第三方依赖，iOS 15+。

## 三个文件

| 文件 | 干什么 |
|---|---|
| `Sources/BLEManager.swift` | 蓝牙状态机：扫描 → 逐个试连 → ack 验证 → 握手 → 开锁 |
| `Sources/ContentView.swift` | 界面：大圆按钮、状态行、日志、设置面板 |
| `Sources/DormLockApp.swift` | 入口，9 行 |

`project.yml` 是 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 的配置，用它生成 `.xcodeproj`，这样仓库里不用提交 `.pbxproj` 那一坨。

## 编出 IPA

**路线 A：GitHub Actions（推荐，不用 Mac）**

推到 GitHub 后 `.github/workflows/ios.yml` 会自动跑。编完在 Actions 页面下 artifact `DormLock-unsigned-ipa`，里面是 `DormLock.ipa`。

**路线 B：本地 Mac**

```bash
brew install xcodegen
cd ios
xcodegen generate
open DormLock.xcodeproj      # 选自己的设备直接 Run，Xcode 会自动签名
```

## 签名安装（Windows 也能做）

未签名 IPA 装不上，必须过一道签名：

```bash
# 用 Sideloadly：插上 iPhone → 拖入 IPA → 填 Apple ID → Start
# 免费 Apple ID 7 天有效，过期重签即可
```

装完还要两步：

1. **设置 → 通用 → VPN与设备管理** → 信任你的开发者证书
2. iOS 16+：**设置 → 隐私与安全性 → 开发者模式** → 打开 → 重启手机

> Windows 上如果 Sideloadly 显示 `<no devices detected>`：先装 iTunes 或「爱思助手」把苹果 USB 驱动装上。iTunes 12 那个包其实不含驱动，用爱思助手更快。

## 第一次运行的坑

**iOS 拿不到 BLE 的真实 MAC。** `CBPeripheral` 只给一个 UUID，所以没法像安卓那样直接按地址连。

所以第一次运行是这样的：

```
扫描 3 秒 → 收集所有设备按信号强度排序
   → 依次连接
   → 用 activationKey 派生的 sessionKey 解建链 ack
      ├─ 解出 FF13…  → 就是它，记住 UUID，开锁
      └─ 解出乱码     → 邻居的锁，断开，试下一台
   → 全都不是 → 重新扫，最多 3 轮
```

宿舍楼里同型号锁多的时候，第一轮可能要试三四台，十几秒。**一旦验证成功会记住这台锁的 UUID，下次打开直接连，一秒都不用等。**

## 设置面板

界面底部的「设置」里可以改：

- `activationKey` —— 换锁时改这个
- 设备名关键字 —— 默认 `TmallLock`，如果广播名不一样就改这里
- 「清除已记住的设备」—— 换了宿舍、或者记错了锁时用

## 已过期 / 想长期用

| 方案 | 有效期 |
|---|---|
| Sideloadly | 7 天 |
| AltStore（装电脑上自动续） | 7 天，自动 |
| SideStore | 7 天，手机自动续 |
| TrollStore（iOS 14.0–16.6.1 / 17.0） | 永久 |
| 开发者账号 $99/年 | 1 年 |
