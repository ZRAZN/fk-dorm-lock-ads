# 网页版

纯静态，没有构建步骤，没有框架。一个 HTML 文件就是全部。

| 文件 | 给谁用 |
|---|---|
| `index.html` | 安卓 Chrome / 桌面 Chrome、Edge |
| `ios.html` | iPhone 上的 **Bluefy** 浏览器 |
| `serve.py` | 本地 HTTPS 服务（首次运行自动生成证书） |
| `crypto-js.min.js` | AES 实现（已本地化，不依赖 CDN） |

## 为什么要自己起 HTTPS

Web Bluetooth 只在**安全上下文**下可用：`https://` 或 `localhost`。

手机通过局域网 IP 访问，属于「非安全上下文」，浏览器会直接抛：

```
Web Bluetooth is not supported on this platform.
```

所以必须给个 HTTPS。`serve.py` 做的就是这件事。

## 跑起来

```bash
cd web
python serve.py
```

首次运行会生成 `cert.pem` / `key.pem`（90 天，SAN 里已包含本机局域网 IP）。

终端会打印：

```
  手机打开:  https://192.168.1.23:8443/
```

手机连同一个 WiFi，浏览器打开这个地址。**证书警告点「高级 → 继续前往」**，自签证书必然报警告，正常。

## 浏览器要求

| 平台 | 能用的浏览器 |
|---|---|
| 安卓 | Chrome、Edge、Opera（**不要用系统自带浏览器、UC、QQ 浏览器**，它们用的老内核不支持） |
| iOS | **只有 Bluefy**（App Store 免费），Safari 及所有 iOS 浏览器都不支持 |
| 桌面 | Chrome、Edge |

## 改参数

两个输入框直接填，会自动存进 `localStorage`：

- MAC（`index.html` 才用，iOS 拿不到 MAC）
- activationKey

留空的话打开页面就是空的，需要每次手填 —— 想预填就改 `index.html` 里这两行：

```js
$("mac").value = localStorage.getItem("voc_mac") || "AA:BB:CC:DD:EE:FF";
$("key").value = localStorage.getItem("voc_key") || "填你的activationKey";
```

## 认锁逻辑

第一次点按钮 → 浏览器弹设备列表 → 选名字带 `TmallLock` 的那台。

**列表里可能有好几台同名的**（隔壁宿舍也是这型号）。选错了会怎样：

- 建链那一步解不出 `FF13…` → 提示「ack 不匹配」，断开重选
- 选对了 → 正常开锁，浏览器记住这台设备

之后再点就不弹列表了（`navigator.bluetooth.getDevices()` 直接拿回已授权的设备）。

## 部署到公网

想让不在同一 WiFi 的人也能用（比如自己在外网），把这个目录扔到任何支持 HTTPS 的静态托管上就行：GitHub Pages、Vercel、Netlify、Cloudflare Pages 都可以，**不需要后端**。

前提是浏览器有 Web Bluetooth —— 也就是说对方得在电脑 Chrome 或安卓 Chrome 上打开。

## 排障

| 现象 | 原因 |
|---|---|
| `Web Bluetooth is not supported` | 不是 HTTPS，或浏览器不支持。换 Chrome / 用 Bluefy |
| 弹不出设备列表 | 安卓系统定位没开（扫描依赖它） |
| 列表里没有门锁 | 离太远，走近点；或者门锁在省电休眠，按一下门锁面板唤醒 |
| 连上就断 | 另一台设备（官方 App？）还连着这把锁，先关掉 |
| `ack 不匹配` | 选了别人家的锁，重选 |
| 一直卡在「建立加密链路」 | activationKey 填错了 |
