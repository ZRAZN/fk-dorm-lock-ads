import Foundation
import CoreBluetooth
import CommonCrypto
import UIKit

/// VOC 蓝牙门锁客户端（iOS / CoreBluetooth 版）
///
/// 协议基于某款宿舍门锁 App 的客户端行为分析
///
/// 与 Android 版的唯一架构差异：
///   iOS 不暴露蓝牙 MAC 地址，peripheral 只有 identifier(UUID)。
///   所以「记住设备」存的是 UUID，首次配对靠广播名关键字匹配。
final class BLEManager: NSObject, ObservableObject {

    // MARK: - 协议常量

    static let serviceUUID = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E1001")

    /// ① 请求随机数
    static let randomReq: [UInt8] = [0x55, 0xAA, 0xFF, 0x0D, 0x00, 0x00, 0x0B]
    /// ③ 建立加密链路
    static let linkEstab: [UInt8] = [0x55, 0xAA, 0xFF, 0x13, 0x00, 0x00, 0x11]
    /// ④ 开锁明文（固定，无时间戳无计数器）
    static let unlockPlainHex = "FF0B0000090000000000000000000000"

    /// BLE 默认 MTU 23 → 单包载荷 20 字节，21 字节的开锁帧必须拆 20+1
    static let chunkSize = 20
    /// 收到数据后静默这么久就算一帧收完（门锁会话超时很紧，不能等太久）
    static let rxQuiet: TimeInterval = 0.15

    // MARK: - 对外状态

    @Published var lines: [String] = []
    @Published var status = "准备"
    @Published var busy = false
    @Published var ok: Bool?

    // MARK: - 配置（UserDefaults 持久化）

    var activationKey: String {
        get { UserDefaults.standard.string(forKey: "voc_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "voc_key") }
    }

    /// 广播名关键字。门锁广播名形如 `~vTmallLock`（示例，以扫描到的为准），iOS 只能靠这个认设备。
    var nameHint: String {
        get { UserDefaults.standard.string(forKey: "voc_name") ?? "TmallLock" }
        set { UserDefaults.standard.set(newValue, forKey: "voc_name") }
    }

    private var savedUUID: String? {
        get { UserDefaults.standard.string(forKey: "voc_uuid") }
        set { UserDefaults.standard.set(newValue, forKey: "voc_uuid") }
    }

    // MARK: - 内部状态

    private var central: CBCentralManager!
    private var periph: CBPeripheral?
    private var writeCh: CBCharacteristic?
    private var notifyCh: CBCharacteristic?

    /// 0 idle / 1 等随机数 / 2 等建链 ack / 3 等开锁响应
    private var phase = 0

    private var txQueue: [Data] = []
    private var sending = false
    private var rx = Data()
    private var rxWork: DispatchWorkItem?

    private var randomNumber = ""
    private var sessionKey = ""
    private var unlockRetry = 0
    private var connectRetry = 0
    private var scanRound = 0

    private var candidates: [(CBPeripheral, Int)] = []
    private var scanWork: DispatchWorkItem?
    private var inSession = false
    private var autoWanted = false

    /// 宿舍楼里有几十把同型号锁，广播名全是 ~vTmallLock，光靠名字分不出哪台是我们的。
    /// 所以按信号强度排出候选队列，逐台连接并用激活码验证建链 ack —— 只有我们的锁会 ack 成功。
    private var tryList: [CBPeripheral] = []
    private var tryIndex = 0
    /// 主动断开的那台设备，它的 didDisconnect 回调要忽略，避免误触发重连
    private var ignoredDisconnect: UUID?

    // MARK: - 生命周期

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// 打开 App 自动开锁
    func autoStart() {
        autoWanted = true
        if central.state == .poweredOn {
            autoWanted = false
            start()
        }
    }

    func start() {
        guard !busy else { return }
        switch central.state {
        case .poweredOn:
            beginUnlock()
        case .poweredOff:
            status = "蓝牙未开启"
            log("蓝牙未开启，去设置里打开")
        case .unauthorized:
            status = "未授权蓝牙"
            log("蓝牙权限被拒绝，去 设置→门锁 打开")
        case .unsupported:
            status = "设备不支持蓝牙"
        default:
            status = "蓝牙初始化…"
        }
    }

    // MARK: - 主流程

    private func beginUnlock() {
        let key = activationKey.lowercased()
        // 注意：不能用 UInt64(key, radix: 16) 校验 —— 32 位 hex 超出 UInt64 范围会返回 nil
        guard key.count == 32, key.allSatisfy({ $0.isHexDigit }) else {
            status = "activationKey 无效"
            log("activationKey 必须是 32 位 hex")
            return
        }

        ok = nil
        busy = true
        inSession = true
        unlockRetry = 0
        connectRetry = 0
        scanRound = 0
        phase = 0
        rx = Data()
        txQueue.removeAll()
        sending = false
        writeCh = nil
        notifyCh = nil
        periph = nil
        tryList.removeAll()
        tryIndex = 0

        if let s = savedUUID, let u = UUID(uuidString: s) {
            let known = central.retrievePeripherals(withIdentifiers: [u])
            if let p = known.first {
                log("直连已记住的设备 \(p.name ?? "?")")
                tryList = [p]
                tryIndex = 0
                connect(p)
                return
            }
            log("记住的设备不在系统缓存，重新扫描")
        }
        startScan()
    }

    private func startScan() {
        guard inSession else { return }
        scanRound += 1
        if scanRound > 3 {
            fail("附近找不到门锁")
            return
        }
        status = "扫描中…"
        log("扫描附近门锁（第 \(scanRound) 轮）…")
        candidates.removeAll()
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.central.stopScan()
            if self.candidates.isEmpty {
                self.log("这轮没扫到，再扫一次")
                self.startScan()
                return
            }
            // 按信号强度排序：离得最近的最可能是自己宿舍那台
            let sorted = self.candidates.sorted { $0.1 > $1.1 }
            self.tryList = sorted.map { $0.0 }
            self.tryIndex = 0
            self.log("\(sorted.count) 台候选，从信号最强的开始试")
            self.connect(sorted[0].0)
        }
        scanWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: w)
    }

    /// 当前这台验证失败，换下一台候选
    private func nextCandidate() {
        guard inSession else { return }
        if let p = periph {
            ignoredDisconnect = p.identifier
            central.cancelPeripheralConnection(p)
        }
        resetLink()
        tryIndex += 1
        if tryIndex < tryList.count {
            log("试下一台（第 \(tryIndex + 1)/\(tryList.count)）")
            connect(tryList[tryIndex])
        } else if scanRound < 3 {
            log("候选试完了，重新扫一轮")
            startScan()
        } else {
            fail("附近的门锁都不是我们的（或激活码失效）")
        }
    }

    private func resetLink() {
        periph = nil
        writeCh = nil
        notifyCh = nil
        phase = 0
        rx = Data()
        txQueue.removeAll()
        sending = false
        rxWork?.cancel()
        rxWork = nil
    }

    private func connect(_ p: CBPeripheral) {
        scanWork?.cancel()
        scanWork = nil
        central.stopScan()
        periph = p
        p.delegate = self
        status = "连接中…"
        log("连接 \(p.name ?? p.identifier.uuidString)")
        central.connect(p, options: nil)
    }

    private func retryOrReconnect() {
        guard inSession else { return }
        if connectRetry < 1 {
            connectRetry += 1
            log("重试连接 \(connectRetry)/1")
            resetLink()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.inSession, self.tryIndex < self.tryList.count else { return }
                self.connect(self.tryList[self.tryIndex])
            }
        } else {
            nextCandidate()
        }
    }

    // MARK: - 握手

    private func beginHandshake() {
        phase = 1
        rx = Data()
        log("① 请求随机数")
        status = "握手…"
        send(Self.randomReq)
    }

    private func doUnlock() {
        guard inSession else { return }
        let sk = Self.xorHex(randomNumber, activationKey.lowercased())
        guard let ct = Self.encrypt(sk, Self.unlockPlainHex) else {
            fail("组帧失败")
            return
        }
        let body = "55AA0010" + ct
        let frame = (body + Self.checksum(body)).uppercased()
        log("④ 开锁帧 \(frame)")
        send(Self.bytes(frame))
    }

    // MARK: - 收包

    private func onRxDone() {
        let h = Self.hex(rx)
        rx = Data()
        guard !h.isEmpty else { return }
        log("   ← \(h)")

        switch phase {
        case 1:
            guard h.count >= 46 else {
                fail("随机数响应异常 \(h)")
                return
            }
            let s = h.index(h.startIndex, offsetBy: 14)
            let e = h.index(h.startIndex, offsetBy: 46)
            randomNumber = String(h[s..<e])
            sessionKey = Self.xorHex(randomNumber, activationKey.lowercased())
            log("② sessionKey=\(sessionKey)")
            phase = 2
            log("③ 建立加密链路")
            send(Self.linkEstab)

        case 2:
            // 建链 ack 是验证「这台是不是我们的锁」的唯一凭据：
            // 用我们的 activationKey 派生的 sessionKey 能解出 ff13... 才算对。
            // 隔壁宿舍同型号锁会回一段解不开的密文 —— 直接换下一台。
            var verified = false
            if let ct = Self.pickCipher(h), let pt = Self.decrypt(sessionKey, ct) {
                if pt.hasPrefix("ff13") {
                    verified = true
                    log("   ack=\(pt)")
                } else {
                    log("   ack 不匹配（这台不是我们的锁）\(pt)")
                }
            }
            guard verified else {
                nextCandidate()
                return
            }
            if let p = periph { savedUUID = p.identifier.uuidString }
            phase = 3
            unlockRetry = 0
            // 建链 ack 是 20+1 分包，等尾字节落完再清缓冲发开锁帧
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self else { return }
                self.rx = Data()
                self.doUnlock()
            }

        case 3:
            var good = false
            if let ct = Self.pickCipher(h), let pt = Self.decrypt(sessionKey, ct) {
                log("   解密=\(pt)")
                good = pt.hasPrefix("ff0b")
            }
            if good {
                log("✓ 开锁成功")
                status = "已开锁"
                ok = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                finish()
            } else {
                unlockRetry += 1
                if unlockRetry <= 3 {
                    log("未确认，重试 \(unlockRetry)/3")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.doUnlock()
                    }
                } else {
                    fail("多次无响应")
                }
            }

        default:
            break
        }
    }

    // MARK: - 写包（按 20 字节分包）

    private func send(_ bytes: [UInt8]) {
        var i = 0
        while i < bytes.count {
            let end = min(i + Self.chunkSize, bytes.count)
            txQueue.append(Data(bytes[i..<end]))
            i = end
        }
        pump()
    }

    private func pump() {
        guard !sending, let ch = writeCh, let p = periph, !txQueue.isEmpty else { return }
        let chunk = txQueue.removeFirst()
        sending = true
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(chunk, for: ch, type: type)
        if type == .withoutResponse {
            sending = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                self?.pump()
            }
        }
    }

    // MARK: - 收尾

    private func finish() {
        phase = 0
        inSession = false
        busy = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let p = self.periph else { return }
            self.central.cancelPeripheralConnection(p)
        }
    }

    private func fail(_ msg: String) {
        log("✗ \(msg)")
        status = msg
        ok = false
        busy = false
        inSession = false
        phase = 0
        central.stopScan()
        scanWork?.cancel()
        scanWork = nil
        tryList.removeAll()
        tryIndex = 0
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        if let p = periph {
            central.cancelPeripheralConnection(p)
        }
    }

    // MARK: - 日志

    func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let line = "[\(f.string(from: Date()))] \(s)"
        lines.append(line)
        if lines.count > 400 {
            lines.removeFirst(lines.count - 400)
        }
        print("[DoorLock] \(s)")
    }

    // MARK: - 算法

    static func hex(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    static func bytes(_ h: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = h.startIndex
        while i < h.endIndex {
            guard let j = h.index(i, offsetBy: 2, limitedBy: h.endIndex) else { break }
            out.append(UInt8(h[i..<j], radix: 16) ?? 0)
            i = j
        }
        return out
    }

    static func xorHex(_ a: String, _ b: String) -> String {
        let A = bytes(a), B = bytes(b)
        guard !B.isEmpty else { return a }
        return hex(Data(A.enumerated().map { $0.element ^ B[$0.offset % B.count] }))
    }

    static func checksum(_ h: String) -> String {
        let s = bytes(h).reduce(0) { ($0 + Int($1)) & 0xFF }
        return String(format: "%02x", s)
    }

    /// AES-128-ECB / NoPadding
    static func aes(_ key: [UInt8], _ data: [UInt8], decrypt: Bool) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        var status = CCCryptorStatus(kCCSuccess)
        key.withUnsafeBytes { kp in
            data.withUnsafeBytes { dp in
                out.withUnsafeMutableBytes { op in
                    status = CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt),
                                     CCAlgorithm(kCCAlgorithmAES),
                                     CCOptions(kCCOptionECBMode),
                                     kp.baseAddress, kCCKeySizeAES128, nil,
                                     dp.baseAddress, data.count,
                                     op.baseAddress, op.count,
                                     &moved)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Array(out[0..<moved])
    }

    static func encrypt(_ keyHex: String, _ plainHex: String) -> String? {
        guard let o = aes(bytes(keyHex), bytes(plainHex), decrypt: false) else { return nil }
        return hex(Data(o))
    }

    static func decrypt(_ keyHex: String, _ ctHex: String) -> String? {
        guard let o = aes(bytes(keyHex), bytes(ctHex), decrypt: true) else { return nil }
        return hex(Data(o))
    }

    /// 在收到的 hex 流里定位 `55aa0010` 帧，取后面 16 字节密文。
    /// 分包可能把上一帧的尾字节混进来，绝不能写死 substring(8,40)。
    static func pickCipher(_ h: String) -> String? {
        let s = h.lowercased()
        var from = s.startIndex
        while let r = s.range(of: "55aa0010", range: from..<s.endIndex) {
            let start = s.index(r.lowerBound, offsetBy: 8, limitedBy: s.endIndex)
            if let start, let end = s.index(start, offsetBy: 32, limitedBy: s.endIndex) {
                return String(s[start..<end])
            }
            from = s.index(after: r.lowerBound)
        }
        return nil
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("蓝牙就绪")
            if autoWanted {
                autoWanted = false
                start()
            } else if !busy {
                status = "就绪"
            }
        case .poweredOff:
            status = "蓝牙未开启"
            log("蓝牙被关闭")
        case .unauthorized:
            status = "未授权蓝牙"
        case .unsupported:
            status = "设备不支持蓝牙"
        default:
            status = "蓝牙不可用"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard inSession, phase == 0, periph == nil else { return }
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""
        guard !name.isEmpty, name.contains(nameHint) else { return }

        if let idx = candidates.firstIndex(where: { $0.0.identifier == peripheral.identifier }) {
            candidates[idx].1 = RSSI.intValue
        } else {
            candidates.append((peripheral, RSSI.intValue))
            log("发现 \(name) rssi=\(RSSI.intValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("已连接，发现服务…")
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        log("连接失败 \(error?.localizedDescription ?? "")")
        retryOrReconnect()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        let msg = error?.localizedDescription ?? ""
        log("断开 \(msg)")
        if peripheral.identifier == ignoredDisconnect {
            ignoredDisconnect = nil
            return
        }
        if inSession {
            retryOrReconnect()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            fail("没有门锁服务，连错设备了")
            return
        }
        peripheral.discoverCharacteristics(nil, for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let cs = service.characteristics else {
            fail("读不到特征")
            return
        }
        for c in cs {
            if c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) {
                writeCh = c
            }
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                notifyCh = c
            }
        }
        guard let n = notifyCh, writeCh != nil else {
            fail("特征不完整 write=\(writeCh != nil) notify=\(notifyCh != nil)")
            return
        }
        log("✓ 特征就绪")
        peripheral.setNotifyValue(true, for: n)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error {
            fail("开 notify 失败 \(e.localizedDescription)")
            return
        }
        log("notify 已开启")
        beginHandshake()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let d = characteristic.value, !d.isEmpty else { return }
        rx.append(d)
        rxWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.onRxDone() }
        rxWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rxQuiet, execute: w)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        sending = false
        pump()
    }
}
