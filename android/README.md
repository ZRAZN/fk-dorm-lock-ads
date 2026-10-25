# 安卓版

单 Activity、零第三方依赖、全部逻辑在一个文件里：`app/src/main/java/com/dorm/lock/MainActivity.java`。

## 改参数

打开 `MainActivity.java`，第 51～52 行：

```java
static final String TARGET_MAC      = "AA:BB:CC:DD:EE:FF";                // ← 你的门锁 MAC
static final String ACTIVATION_KEY  = "00000000000000000000000000000000"; // ← 你的 activationKey
```

两个值都是占位符，不改的话开不了门。怎么拿见[主 README](../README.md#怎么拿到自己的-activationkey)。

## 编译

需要 **JDK 17** 和 **Android SDK（compileSdk 34）**。

```bash
# 1. 告诉 Gradle SDK 在哪
echo "sdk.dir=/path/to/Android/Sdk" > local.properties
#    （Windows 下路径要转义，写成 D\:\\Android\\Sdk）

# 2. 编（仓库自带 wrapper，不用自己装 Gradle）
./gradlew assembleDebug          # Windows: gradlew.bat assembleDebug

# 3. 装
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

第一次跑 wrapper 会下载 Gradle 8.7（约 100MB）。

没有 JDK 也没有 SDK 的话，直接用 Android Studio 打开 `android/` 目录，它会提示装缺失的组件，然后点 Run。

## 授权

首次运行会申请蓝牙权限，同意就行。Android 12 以上申请的是 `BLUETOOTH_SCAN` + `BLUETOOTH_CONNECT`；如果手滑拒绝了，去 设置 → 应用 → 门锁 → 权限 里重新给。

也可以命令行直接授：

```bash
adb shell pm grant com.dorm.lock android.permission.BLUETOOTH_SCAN
adb shell pm grant com.dorm.lock android.permission.BLUETOOTH_CONNECT
```

## 行为

```
启动 → 申请权限 → 直连 TARGET_MAC → 握手 → 开锁 → 震动 + "已开锁"
                              ↓ 连接失败
                        回退到扫描匹配 MAC
                              ↓ 仍失败
                        重连 2 次后放弃，界面报错
```

直连（`adapter.getRemoteDevice(mac).connect()`）不需要先扫描，比扫描快 2～3 秒，官方 App 也是这么做的。连接状态码 `133`（GATT_ERROR）很常见，代码里会自动重连两次。

## 日志

所有过程同时写到界面和 logcat，TAG 是 `DoorLock`：

```bash
adb logcat -s DoorLock
```

会看到每一步的原始 hex，排查问题时发这个就够了。

## 换宿舍 / 换锁

改上面两个常量，重新编译安装。没有其他状态需要清。
