package com.dorm.lock;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.text.SimpleDateFormat;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Date;
import java.util.Deque;
import java.util.List;
import java.util.Locale;
import java.util.UUID;

import javax.crypto.Cipher;
import javax.crypto.spec.SecretKeySpec;

public class MainActivity extends Activity {

    /* ================= 配置 ================= */
    static final String TARGET_MAC = "AA:BB:CC:DD:EE:FF";   // ← 改成自己门锁的 MAC
    static final String ACTIVATION_KEY = "00000000000000000000000000000000"; // ← 改成自己门锁的 activationKey（32 位 hex）

    static final UUID SVC_UUID = UUID.fromString("00002760-08c2-11e1-9073-0e8ac72e1001");
    static final UUID CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");

    static final String RANDOM_REQ = "55AAFF0D00000B";
    static final String LINK_ESTAB = "55AAFF13000011";
    static final String UNLOCK_PLAIN = "FF0B0000090000000000000000000000";

    static final int STEP_IDLE = 0;
    static final int STEP_RANDOM = 1;
    static final int STEP_ESTAB = 2;
    static final int STEP_UNLOCK = 3;

    /* ================= 状态 ================= */
    private TextView logView, statusView;
    private Button bigBtn;

    private BluetoothAdapter adapter;
    private BluetoothGatt gatt;
    private BluetoothGattCharacteristic writeCh, notifyCh;
    private final Handler ui = new Handler(Looper.getMainLooper());

    private final StringBuilder rx = new StringBuilder();
    private Runnable rxFired;
    private int step = STEP_IDLE;
    private String randomNumber, sessionKey;
    private boolean unlocking = false;
    private int unlockRetry = 0;

    private final Deque<byte[]> writeQueue = new ArrayDeque<>();
    private boolean writing = false;
    /** 防重复：服务发现 / 握手 / 发开锁帧 各只跑一次 */
    private boolean servicesReady = false, handshakeStarted = false, unlockSent = false;

    private final List<String> found = new ArrayList<>();
    private final SimpleDateFormat ts = new SimpleDateFormat("HH:mm:ss", Locale.US);

    /* ================= 生命周期 ================= */
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        buildUi();
        BluetoothManager bm = (BluetoothManager) getSystemService(Context.BLUETOOTH_SERVICE);
        adapter = bm == null ? null : bm.getAdapter();
        if (adapter == null || !adapter.isEnabled()) {
            log("蓝牙未开启，请先打开蓝牙", "#ff6b6b");
        } else {
            log("就绪，点按钮开锁", "#8a8a96");
        }
        ensurePerms();
        if (hasPerms()) ui.postDelayed(this::autoUnlock, 400);
    }

    private boolean hasPerms() {
        if (Build.VERSION.SDK_INT >= 31) {
            return checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
                    && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED;
        }
        return true;
    }

    /**
     * NFC 贴片 / 快捷方式再次唤起时走这里（配合 singleTask）。
     * 碰一下 = 重开一次，不用退出软件。
     */
    @Override
    protected void onNewIntent(android.content.Intent it) {
        super.onNewIntent(it);
        setIntent(it);
        if (hasPerms()) ui.postDelayed(this::autoUnlock, 300);
    }

    /** 打开软件即自动开锁 */
    private void autoUnlock() {
        if (unlocking) return;
        if (adapter == null || !adapter.isEnabled()) {
            status("请先打开蓝牙", Color.parseColor("#ff6b6b"));
            return;
        }
        log("自动开锁", "#8a8a96");
        startUnlock();
    }

    @Override
    public void onRequestPermissionsResult(int rc, String[] p, int[] res) {
        super.onRequestPermissionsResult(rc, p, res);
        if (hasPerms()) ui.postDelayed(this::autoUnlock, 300);
    }

    private void ensurePerms() {
        if (Build.VERSION.SDK_INT >= 31) {
            List<String> need = new ArrayList<>();
            if (checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED)
                need.add(Manifest.permission.BLUETOOTH_SCAN);
            if (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED)
                need.add(Manifest.permission.BLUETOOTH_CONNECT);
            if (!need.isEmpty()) requestPermissions(need.toArray(new String[0]), 1);
        } else if (Build.VERSION.SDK_INT >= 23) {
            if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED)
                requestPermissions(new String[]{Manifest.permission.ACCESS_FINE_LOCATION}, 1);
        }
    }

    /* ================= UI ================= */
    private void buildUi() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.parseColor("#0b0b0d"));
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        int pad = dp(20);
        root.setPadding(pad, dp(56), pad, pad);

        TextView title = new TextView(this);
        title.setText("宿 舍 门 锁");
        title.setTextColor(Color.parseColor("#888888"));
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 17);
        title.setLetterSpacing(0.12f);
        root.addView(title);

        statusView = new TextView(this);
        statusView.setTextColor(Color.parseColor("#8a8a96"));
        statusView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        statusView.setPadding(0, dp(10), 0, dp(6));
        root.addView(statusView);

        bigBtn = new Button(this);
        LinearLayout.LayoutParams bp = new LinearLayout.LayoutParams(dp(190), dp(190));
        bp.topMargin = dp(18);
        bp.bottomMargin = dp(22);
        bigBtn.setLayoutParams(bp);
        bigBtn.setText("开锁");
        bigBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 26);
        bigBtn.setTextColor(Color.WHITE);
        bigBtn.setBackground(makeCircle());
        bigBtn.setAllCaps(false);
        bigBtn.setOnClickListener(v -> startUnlock());
        root.addView(bigBtn);

        ScrollView sv = new ScrollView(this);
        LinearLayout.LayoutParams sp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f);
        sv.setLayoutParams(sp);
        logView = new TextView(this);
        logView.setTextColor(Color.parseColor("#8a8a96"));
        logView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        logView.setTypeface(android.graphics.Typeface.MONOSPACE);
        logView.setPadding(dp(12), dp(12), dp(12), dp(12));
        logView.setBackgroundColor(Color.parseColor("#15151a"));
        logView.setTextIsSelectable(true);
        sv.addView(logView);
        root.addView(sv);

        setContentView(root);
    }

    private android.graphics.drawable.GradientDrawable makeCircle() {
        android.graphics.drawable.GradientDrawable g = new android.graphics.drawable.GradientDrawable();
        g.setShape(android.graphics.drawable.GradientDrawable.OVAL);
        g.setColors(new int[]{Color.parseColor("#3a3a44"), Color.parseColor("#1a1a20")});
        g.setGradientType(android.graphics.drawable.GradientDrawable.RADIAL_GRADIENT);
        g.setGradientRadius(dp(120));
        g.setGradientCenter(0.35f, 0.30f);
        return g;
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    private void log(String msg, String color) {
        android.util.Log.d("DoorLock", msg);
        ui.post(() -> {
            logView.append("[" + ts.format(new Date()) + "] " + msg + "\n");
        });
    }

    private void status(String msg, int color) {
        ui.post(() -> {
            statusView.setText(msg);
            statusView.setTextColor(color);
        });
    }

    private void flash(boolean ok) {
        ui.post(() -> {
            bigBtn.setText(ok ? "已开" : "失败");
            if (ok) {
                Vibrator v = (Vibrator) getSystemService(Context.VIBRATOR_SERVICE);
                if (v != null) {
                    if (Build.VERSION.SDK_INT >= 26)
                        v.vibrate(VibrationEffect.createWaveform(new long[]{0, 45, 60, 45}, -1));
                    else v.vibrate(180);
                }
            }
            ui.postDelayed(() -> {
                bigBtn.setText("开锁");
                unlocking = false;
            }, 1800);
        });
    }

    /* ================= 开锁入口 ================= */
    private void startUnlock() {
        if (unlocking) return;
        if (adapter == null || !adapter.isEnabled()) {
            log("蓝牙没开", "#ff6b6b");
            status("请先打开蓝牙", Color.parseColor("#ff6b6b"));
            return;
        }
        unlocking = true;
        unlockRetry = 0;
        connectRetry = 0;
        step = STEP_IDLE;
        servicesReady = false;
        handshakeStarted = false;
        unlockSent = false;
        rx.setLength(0);
        found.clear();
        status("连接中…", Color.parseColor("#ffd166"));
        // 官方 App 就是 skip scan + direct connect，省掉 1~2 秒扫描
        log("直连 " + TARGET_MAC, null);
        try {
            BluetoothDevice d = adapter.getRemoteDevice(TARGET_MAC);
            connect(d);
        } catch (Exception e) {
            log("直连失败，改扫描", "#ffd166");
            startScan();
        }
    }

    /* ================= 扫描 ================= */
    private BluetoothLeScanner scanner() {
        return adapter.getBluetoothLeScanner();
    }

    private final ScanCallback scanCb = new ScanCallback() {
        @Override
        public void onScanResult(int type, ScanResult r) {
            BluetoothDevice d = r.getDevice();
            String addr = d.getAddress();
            String name = d.getName();
            String line = addr + "  " + (name == null ? "(无名)" : name) + "  rssi=" + r.getRssi();
            if (!found.contains(addr)) found.add(addr);
            boolean isLock = name != null && name.contains("TmallLock");
            if (isLock) log("发现门锁 " + line, null);

            if (addr != null && addr.equalsIgnoreCase(TARGET_MAC)) {
                log("✓ 地址匹配目标锁", "#5fd97f");
                stopScan();
                connect(d);
            }
        }

        @Override
        public void onScanFailed(int code) {
            log("扫描失败 code=" + code, "#ff6b6b");
            status("扫描失败 " + code, Color.parseColor("#ff6b6b"));
            unlocking = false;
        }
    };

    private boolean scanning = false;

    private void startScan() {
        BluetoothLeScanner s = scanner();
        if (s == null) { log("扫描器不可用", "#ff6b6b"); unlocking = false; return; }
        ScanSettings st = new ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .build();
        scanning = true;
        s.startScan(null, st, scanCb);
        ui.postDelayed(() -> {
            if (scanning) {
                stopScan();
                log("扫描结束，没找到 " + TARGET_MAC + "，共发现 " + found.size() + " 台", "#ff6b6b");
                status("没找到门锁（蓝牙地址是随机的话需要换匹配方式）", Color.parseColor("#ff6b6b"));
                unlocking = false;
            }
        }, 12000);
    }

    private void stopScan() {
        if (!scanning) return;
        scanning = false;
        try {
            BluetoothLeScanner s = scanner();
            if (s != null) s.stopScan(scanCb);
        } catch (Exception ignored) { }
    }

    /* ================= GATT ================= */
    private BluetoothDevice target;
    private int connectRetry = 0;

    private void connect(BluetoothDevice d) {
        target = d;
        status("连接中…", Color.parseColor("#ffd166"));
        log("连接 " + d.getAddress(), null);
        gatt = d.connectGatt(this, false, gattCb, BluetoothDevice.TRANSPORT_LE);
    }

    private final BluetoothGattCallback gattCb = new BluetoothGattCallback() {
        @Override
        public void onConnectionStateChange(BluetoothGatt g, int status, int newState) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                log("已连接，发现服务…", "#5fd97f");
                g.discoverServices();
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                log("断开 status=" + status, null);
                if (unlocking && step == STEP_IDLE && status == 133) {
                    if (connectRetry < 2) {
                        connectRetry++;
                        log("连接被拒(133)，重试 " + connectRetry + "/2", "#ffd166");
                        try { g.close(); } catch (Exception ignored) { }
                        gatt = null;
                        ui.postDelayed(() -> { if (target != null) connect(target); }, 800);
                    } else {
                        log("直连失败，改扫描", "#ffd166");
                        try { g.close(); } catch (Exception ignored) { }
                        gatt = null;
                        startScan();
                    }
                } else if (unlocking && step == STEP_IDLE) {
                    log("✗ 连不上门锁", "#ff6b6b");
                    fail();
                }
            }
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt g, int status) {
            if (servicesReady) return;
            servicesReady = true;
            BluetoothGattService svc = g.getService(SVC_UUID);
            if (svc == null) {
                log("✗ 没有门锁服务，连错设备了", "#ff6b6b");
                status("连错设备", Color.parseColor("#ff6b6b"));
                g.disconnect();
                unlocking = false;
                return;
            }
            for (BluetoothGattCharacteristic c : svc.getCharacteristics()) {
                int p = c.getProperties();
                if ((p & BluetoothGattCharacteristic.PROPERTY_WRITE) != 0
                        || (p & BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0) writeCh = c;
                if ((p & BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0
                        || (p & BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0) notifyCh = c;
            }
            if (writeCh == null || notifyCh == null) {
                log("✗ 特征不完整 write=" + (writeCh != null) + " notify=" + (notifyCh != null), "#ff6b6b");
                unlocking = false;
                g.disconnect();
                return;
            }
            log("✓ 服务/特征就绪", "#5fd97f");
            g.setCharacteristicNotification(notifyCh, true);
            BluetoothGattDescriptor d = notifyCh.getDescriptor(CCCD_UUID);
            if (d != null) {
                d.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
                g.writeDescriptor(d);
            } else {
                beginHandshake();
            }
        }

        @Override
        public void onDescriptorWrite(BluetoothGatt g, BluetoothGattDescriptor d, int status) {
            log("notify 已开启", null);
            beginHandshake();
        }

        @Override
        public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
            writing = false;
            pumpQueue();
        }

        @Override
        public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c) {
            String h = bytesToHex(c.getValue());
            rx.append(h);
            if (rxFired != null) ui.removeCallbacks(rxFired);
            rxFired = () -> onRxDone(rx.toString());
            ui.postDelayed(rxFired, 130);
        }
    };

    /* ================= 握手 ================= */
    private void beginHandshake() {
        if (handshakeStarted) return;
        handshakeStarted = true;
        step = STEP_RANDOM;
        rx.setLength(0);
        log("① 请求随机数", null);
        status("握手…", Color.parseColor("#ffd166"));
        send(hexToBytes(RANDOM_REQ));
    }

    private void onRxDone(String h) {
        rxFired = null;
        if (h.isEmpty()) return;
        log("   ← " + h, null);

        if (step == STEP_RANDOM) {
            if (h.length() < 46) { log("随机数响应太短", "#ff6b6b"); fail(); return; }
            randomNumber = h.substring(14, 46);
            sessionKey = xorHex(randomNumber, ACTIVATION_KEY);
            log("② sessionKey=" + sessionKey, null);
            step = STEP_ESTAB;
            rx.setLength(0);
            log("③ 建立加密链路", null);
            send(hexToBytes(LINK_ESTAB));

        } else if (step == STEP_ESTAB) {
            String ct = pickCipher(h);
            if (ct != null) {
                try {
                    String pt = bytesToHex(aesEcbDec(hexToBytes(sessionKey), hexToBytes(ct)));
                    log("   ack=" + pt, null);
                    android.util.Log.d("DoorLock", "ESTAB ack=" + pt);
                } catch (Exception e) { log("ack 解密失败 " + e, "#ff6b6b"); }
            }
            step = STEP_UNLOCK;
            // 建链 ACK 是 20+1 分包，尾字节可能还没到；等它落完再清缓冲发开锁帧，
            // 否则残留字节会把开锁响应的帧头挤歪。
            ui.postDelayed(() -> { rx.setLength(0); doUnlock(); }, 180);

        } else if (step == STEP_UNLOCK) {
            boolean ok = false;
            String ct = pickCipher(h);
            if (ct != null) {
                try {
                    String pt = bytesToHex(aesEcbDec(hexToBytes(sessionKey), hexToBytes(ct)));
                    log("   解密=" + pt, null);
                    android.util.Log.d("DoorLock", "UNLOCK resp=" + pt);
                    ok = pt.startsWith("ff0b") && pt.contains("0001");
                } catch (Exception e) { log("解密失败 " + e, "#ff6b6b"); }
            }
            if (ok) {
                log("✓ 开锁成功", "#5fd97f");
                status("已开锁", Color.parseColor("#5fd97f"));
                flash(true);
                finishSession();
            } else {
                unlockRetry++;
                if (unlockRetry <= 3) {
                    log("未确认，重试 " + unlockRetry + "/3", "#ffd166");
                    rx.setLength(0);
                    unlockSent = false;
                    ui.postDelayed(this::doUnlock, 250);
                } else {
                    log("✗ 多次无响应", "#ff6b6b");
                    fail();
                }
            }
        }
    }

    private void doUnlock() {
        if (unlockSent) return;
        unlockSent = true;
        try {
            String frame = buildUnlockFrame(randomNumber, ACTIVATION_KEY);
            log("④ 开锁帧 " + frame, null);
            send(hexToBytes(frame));
        } catch (Exception e) {
            log("组帧失败 " + e, "#ff6b6b");
            fail();
        }
    }

    private void fail() {
        status("开锁失败", Color.parseColor("#ff6b6b"));
        flash(false);
        finishSession();
    }

    private void finishSession() {
        step = STEP_IDLE;
        ui.postDelayed(() -> {
            try {
                if (gatt != null) { gatt.disconnect(); gatt.close(); }
            } catch (Exception ignored) { }
            gatt = null;
            writeCh = notifyCh = null;
            writeQueue.clear();
            writing = false;
        }, 300);
    }

    /* ================= 写队列（按 MTU 分包） ================= */
    private void send(byte[] data) {
        final int MTU = 20;
        for (int i = 0; i < data.length; i += MTU) {
            writeQueue.add(Arrays.copyOfRange(data, i, Math.min(i + MTU, data.length)));
        }
        pumpQueue();
    }

    private void pumpQueue() {
        if (writing || writeCh == null || gatt == null) return;
        byte[] chunk = writeQueue.poll();
        if (chunk == null) return;
        writing = true;
        writeCh.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);
        writeCh.setValue(chunk);
        boolean ok = gatt.writeCharacteristic(writeCh);
        if (!ok) {
            writing = false;
            log("写入失败", "#ff6b6b");
            fail();
        }
    }

    /* ================= 算法 ================= */
    static byte[] hexToBytes(String s) {
        int n = s.length() / 2;
        byte[] r = new byte[n];
        for (int i = 0; i < n; i++)
            r[i] = (byte) Integer.parseInt(s.substring(i * 2, i * 2 + 2), 16);
        return r;
    }

    static String bytesToHex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte x : b) sb.append(String.format("%02x", x & 0xFF));
        return sb.toString();
    }

    static String xorHex(String a, String b) {
        byte[] x = hexToBytes(a), y = hexToBytes(b);
        byte[] r = new byte[x.length];
        for (int i = 0; i < x.length; i++) r[i] = (byte) (x[i] ^ y[i % y.length]);
        return bytesToHex(r);
    }

    static String checksum(String hex) {
        int s = 0;
        for (int i = 0; i < hex.length(); i += 2)
            s += Integer.parseInt(hex.substring(i, i + 2), 16);
        return String.format("%02x", s & 0xFF);
    }

    static byte[] aesEcb(byte[] key, byte[] data) throws Exception {
        Cipher c = Cipher.getInstance("AES/ECB/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"));
        return c.doFinal(data);
    }

    /** AES-128-ECB 解密（NoPadding） —— 收包必须用这个，不能用 aesEcb */
    static byte[] aesEcbDec(byte[] key, byte[] data) throws Exception {
        Cipher c = Cipher.getInstance("AES/ECB/NoPadding");
        c.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"));
        return c.doFinal(data);
    }

    /**
     * 在收到的 hex 流里定位 "55aa0010" 帧，取后面 16 字节密文。
     * 分包可能把上一帧的尾巴混进来，所以不能写死 substring(8,40)。
     */
    static String pickCipher(String h) {
        if (h == null) return null;
        String s = h.toLowerCase(Locale.US);
        int i = s.indexOf("55aa0010");
        while (i >= 0) {
            if (i + 40 <= s.length()) return s.substring(i + 8, i + 40);
            i = s.indexOf("55aa0010", i + 2);
        }
        return null;
    }

    static String buildUnlockFrame(String randomNumber, String activationKey) throws Exception {
        String sk = xorHex(randomNumber, activationKey);
        String ct = bytesToHex(aesEcb(hexToBytes(sk), hexToBytes(UNLOCK_PLAIN)));
        String body = "55AA0010" + ct;
        return (body + checksum(body)).toUpperCase(Locale.US);
    }
}
