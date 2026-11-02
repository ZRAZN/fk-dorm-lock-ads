/*
 * 门边 NFC 读卡器 · 刷卡即开门（自动探测接线版）
 * ------------------------------------------------------------
 * 硬件：ESP32-C3 SuperMini + RC522
 *
 * 这一版启动时会自动扫描 SPI 接线组合，找到能读到 RC522 版本号的那一组，
 * 不用再猜 IO5/IO6/IO7 到底对应哪个脚。
 *
 * 灯语：
 *   长闪 1 下        = 探测成功，RC522 可用
 *   闪 3 下          = 探测失败（没有任何组合能读到 0x92）
 *   刷卡后再闪 2 下  = 读到卡
 *   再闪 6 下        = 开锁成功
 *   再闪 4 下        = 开锁失败
 */

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEClient.h>
#include <BLERemoteService.h>
#include <BLERemoteCharacteristic.h>
#include <SPI.h>
#define MFRC522_SPICLOCK 1000000u
#include <MFRC522.h>
#include <mbedtls/aes.h>

// ==================== CONFIG ====================
static const char *LOCK_MAC = "AA:BB:CC:DD:EE:FF";   // 改成你自己门锁的 MAC
static const char *ACTIVATION_KEY = "00000000000000000000000000000000";  // 改成你自己的 activationKey

static const char *SVC_UUID   = "00002760-08c2-11e1-9073-0e8ac72e1001";
static const char *CHUNK_STR  = "55AAFF0D00000B";
static const char *LINK_STR   = "55AAFF13000011";
static const char *UNLOCK_STR = "FF0B0000090000000000000000000000";

#define RST_PIN  3            // RST 固定接 IO3
#define LED_PIN  8            // 板载灯

static const char *ALLOW_UID[] = {
  // "A1B2C3D4",
};
static const int ALLOW_COUNT = sizeof(ALLOW_UID) / sizeof(ALLOW_UID[0]);

// 黑名单：丢了卡就把那张卡的 UID 填进来，重烧固件即可作废，
// 其它卡不受影响（不用重新写卡）。
static const char *DENY_UID[] = {
  // "11223344",
};
static const int DENY_COUNT = sizeof(DENY_UID) / sizeof(DENY_UID[0]);

// ==================== 卡内通行证（防克隆） ====================
// 在卡的第 1 扇区（块 4）写入 16 字节随机口令，并把该扇区密码改成自定义值。
// 之后这张卡只有「UID 在白名单 + 能用自定义 Key 认证 + 读出口令一致」才放行。
// 普通 UID 克隆卡没有这块数据，刷了也不动。
//
// 注意：空白 S50 卡可以写；校园卡/门禁卡通常被学校锁死，写不进去，
//       那种卡只能用上面的 UID 白名单。
#define PASS_BLOCK 4
#ifndef BTN_PIN
#define BTN_PIN 9
#endif

static const uint8_t PASS_KEY_A[6] = { 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };
static const uint8_t PASS_KEY_B[6] = { 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC };
static const uint8_t PASS_TOKEN[16] = {
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};
static const uint8_t FACTORY_KEY[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

// ==================== 全局 ====================
MFRC522 *rfid = nullptr;

BLEClient *client = nullptr;
BLERemoteCharacteristic *chWrite = nullptr;
BLERemoteCharacteristic *chNotify = nullptr;
String rxBuf;
uint32_t rxStamp = 0;

// ==================== 灯 ====================
static void led(bool on) { digitalWrite(LED_PIN, on ? LOW : HIGH); }
static void blink(int n, int ms = 120) {
  for (int i = 0; i < n; i++) { led(true); delay(ms); led(false); delay(ms); }
  delay(250);
}

// ==================== 工具 ====================
static uint8_t hexNibble(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return 0;
}
static void hexToBytes(const String &s, uint8_t *out, int len) {
  for (int i = 0; i < len; i++) out[i] = (hexNibble(s[2 * i]) << 4) | hexNibble(s[2 * i + 1]);
}
static String bytesToHex(const uint8_t *b, int len) {
  static const char *H = "0123456789abcdef";
  String s; s.reserve(len * 2);
  for (int i = 0; i < len; i++) { s += H[b[i] >> 4]; s += H[b[i] & 0x0F]; }
  return s;
}
static uint8_t checksum(const uint8_t *b, int len) {
  uint8_t s = 0; for (int i = 0; i < len; i++) s += b[i]; return s;
}
static bool aesEncrypt(const uint8_t *key, const uint8_t *in, uint8_t *out) {
  mbedtls_aes_context ctx; mbedtls_aes_init(&ctx);
  if (mbedtls_aes_setkey_enc(&ctx, key, 128) != 0) { mbedtls_aes_free(&ctx); return false; }
  int rc = mbedtls_aes_crypt_ecb(&ctx, MBEDTLS_AES_ENCRYPT, in, out);
  mbedtls_aes_free(&ctx); return rc == 0;
}
static void aesDecrypt(const uint8_t *key, const uint8_t *in, uint8_t *out) {
  mbedtls_aes_context ctx; mbedtls_aes_init(&ctx);
  mbedtls_aes_setkey_dec(&ctx, key, 128);
  mbedtls_aes_crypt_ecb(&ctx, MBEDTLS_AES_DECRYPT, in, out);
  mbedtls_aes_free(&ctx);
}

// ==================== SPI 接线自动探测 ====================
// 只在这些脚里找（排除 IO8 板载灯、IO9 启动脚、IO20/21 串口）
static const uint8_t CAND[] = { 0, 1, 2, 4, 5, 6, 7, 10 };
static const int NC = sizeof(CAND) / sizeof(CAND[0]);

static uint8_t probeVersion(uint8_t sck, uint8_t miso, uint8_t mosi, uint8_t ss) {
  SPI.end();
  SPI.begin(sck, miso, mosi, ss);
  pinMode(ss, OUTPUT);
  digitalWrite(ss, HIGH);
  delayMicroseconds(30);
  digitalWrite(ss, LOW);
  SPI.transfer(0xEE);            // (0x37 << 1) | 0x80  → 读 VersionReg
  uint8_t v = SPI.transfer(0x00);
  digitalWrite(ss, HIGH);
  return v;
}

static bool autoDetect(uint8_t &sckOut, uint8_t &misoOut, uint8_t &mosiOut, uint8_t &ssOut) {
  led(true);                     // 扫描期间灯常亮，表示正在探测

  for (int a = 0; a < NC; a++)
    for (int b = 0; b < NC; b++) {
      if (b == a) continue;
      for (int c = 0; c < NC; c++) {
        if (c == a || c == b) continue;
        for (int d = 0; d < NC; d++) {
          if (d == a || d == b || d == c) continue;

          // 把没用到的脚全部拉高：这样不管 RST 实际接在哪个脚上，都能退出复位
          for (int k = 0; k < NC; k++) {
            if (k == a || k == b || k == c || k == d) continue;
            pinMode(CAND[k], OUTPUT);
            digitalWrite(CAND[k], HIGH);
          }
          pinMode(RST_PIN, OUTPUT);
          digitalWrite(RST_PIN, HIGH);
          delay(3);

          uint8_t v = probeVersion(CAND[a], CAND[b], CAND[c], CAND[d]);
          if (v == 0x92 || v == 0x91) {
            sckOut = CAND[a]; misoOut = CAND[b]; mosiOut = CAND[c]; ssOut = CAND[d];
            Serial.printf("FOUND sck=%d miso=%d mosi=%d ss=%d ver=0x%02X\n",
                          sckOut, misoOut, mosiOut, ssOut, v);
            led(false);
            return true;
          }
        }
      }
    }
  led(false);
  return false;
}

// ==================== BLE ====================
static void onNotify(BLERemoteCharacteristic *c, uint8_t *data, size_t len, bool isNotify) {
  (void)c; (void)isNotify;
  rxBuf += bytesToHex(data, (int)len);
  rxStamp = millis();
}
static bool pickCipher(const String &h, String &out) {
  int i = h.indexOf("55aa0010");
  while (i >= 0) {
    if (i + 40 <= (int)h.length()) { out = h.substring(i + 8, i + 40); return true; }
    i = h.indexOf("55aa0010", i + 2);
  }
  return false;
}
static bool waitRx(uint32_t quietMs, uint32_t limitMs) {
  uint32_t t0 = millis();
  while (millis() - t0 < limitMs) {
    if (rxBuf.length() > 0 && millis() - rxStamp > quietMs) return true;
    delay(10);
  }
  return rxBuf.length() > 0;
}
static void writeChunked(const uint8_t *buf, int len) {
  int off = 0;
  while (off < len) {
    int n = (len - off) < 20 ? (len - off) : 20;
    chWrite->writeValue((uint8_t *)(buf + off), n, true);
    off += n;
    if (off < len) delay(40);
  }
}
static void sendFrame(const String &hex) {
  int len = hex.length() / 2;
  uint8_t *b = (uint8_t *)malloc(len);
  hexToBytes(hex, b, len);
  rxBuf = "";
  writeChunked(b, len);
  free(b);
}
static bool connectLock() {
  client = BLEDevice::createClient();
  if (!client->connect(BLEAddress(LOCK_MAC))) {
    Serial.println("[BLE] connect failed");
    delete client; client = nullptr; return false;
  }
  BLERemoteService *svc = client->getService(BLEUUID(SVC_UUID));
  if (!svc) { Serial.println("[BLE] no service"); client->disconnect(); delete client; client = nullptr; return false; }
  chWrite = nullptr; chNotify = nullptr;
  for (auto &kv : *svc->getCharacteristics()) {
    BLERemoteCharacteristic *ch = kv.second;
    if (!chWrite && ch->canWrite())  chWrite = ch;
    if (!chNotify && ch->canNotify()) chNotify = ch;
  }
  if (!chWrite || !chNotify) { Serial.println("[BLE] no char"); client->disconnect(); delete client; client = nullptr; return false; }
  chNotify->registerForNotify(onNotify);
  delay(200);
  return true;
}
static void disconnectLock() {
  chWrite = nullptr; chNotify = nullptr;
  if (client) { client->disconnect(); delete client; client = nullptr; }
}

static bool doUnlock() {
  sendFrame(CHUNK_STR);
  if (!waitRx(120, 1500)) { Serial.println("[1] no random"); return false; }
  int p = rxBuf.indexOf("55aaff0d");
  if (p < 0) { Serial.println("[1] bad frame"); return false; }
  String rnd = rxBuf.substring(p + 14, p + 46);
  Serial.println("[1] random=" + rnd);

  uint8_t r[16], k[16], sk[16];
  hexToBytes(rnd, r, 16);
  hexToBytes(String(ACTIVATION_KEY), k, 16);
  for (int i = 0; i < 16; i++) sk[i] = r[i] ^ k[i];
  Serial.println("[2] sessionKey=" + bytesToHex(sk, 16));

  sendFrame(LINK_STR);
  if (!waitRx(120, 1500)) { Serial.println("[3] no ack"); return false; }
  String ct;
  if (!pickCipher(rxBuf, ct)) { Serial.println("[3] no cipher"); return false; }
  uint8_t cbuf[16], pbuf[16];
  hexToBytes(ct, cbuf, 16);
  aesDecrypt(sk, cbuf, pbuf);
  String pt = bytesToHex(pbuf, 16);
  Serial.println("[3] ack=" + pt);
  if (!pt.startsWith("ff13")) { Serial.println("[3] ack mismatch"); return false; }

  delay(180);

  uint8_t plain[16], cipher[16];
  hexToBytes(String(UNLOCK_STR), plain, 16);
  if (!aesEncrypt(sk, plain, cipher)) { Serial.println("[4] aes fail"); return false; }
  uint8_t frame[21];
  frame[0] = 0x55; frame[1] = 0xAA; frame[2] = 0x00; frame[3] = 0x10;
  memcpy(frame + 4, cipher, 16);
  frame[20] = checksum(frame, 20);

  rxBuf = "";
  writeChunked(frame, 21);
  if (!waitRx(120, 1500)) { Serial.println("[4] no response"); return false; }
  String ct2;
  if (!pickCipher(rxBuf, ct2)) { Serial.println("[4] no cipher"); return false; }
  hexToBytes(ct2, cbuf, 16);
  aesDecrypt(sk, cbuf, pbuf);
  String pt2 = bytesToHex(pbuf, 16);
  Serial.println("[4] resp=" + pt2);
  return pt2.startsWith("ff0b");
}

// ==================== 卡片 ====================
static String cardUid() {
  if (!rfid->PICC_IsNewCardPresent()) return "";
  if (!rfid->PICC_ReadCardSerial()) return "";
  String s = bytesToHex(rfid->uid.uidByte, rfid->uid.size);
  s.toUpperCase();
  rfid->PICC_HaltA();
  return s;
}
static bool allowed(const String &uid) {
  if (ALLOW_COUNT == 0) return true;
  for (int i = 0; i < ALLOW_COUNT; i++) if (uid.equalsIgnoreCase(ALLOW_UID[i])) return true;
  return false;
}

// 校验卡内通行证。返回 0=通过 1=认证失败 2=口令不符 3=读取失败
static int checkPass() {
  MFRC522::MIFARE_Key k;
  memcpy(k.keyByte, PASS_KEY_A, 6);

  MFRC522::StatusCode st =
      rfid->PCD_Authenticate(MFRC522::PICC_CMD_MF_AUTH_KEY_A, PASS_BLOCK, &k, &rfid->uid);
  if (st != MFRC522::STATUS_OK) {
    Serial.printf("  pass: auth fail (%d)\n", (int)st);
    return 1;
  }

  uint8_t buf[18];
  uint8_t len = sizeof(buf);
  st = rfid->MIFARE_Read(PASS_BLOCK, buf, &len);
  if (st != MFRC522::STATUS_OK) {
    Serial.printf("  pass: read fail (%d)\n", (int)st);
    return 3;
  }

  bool same = (memcmp(buf, PASS_TOKEN, 16) == 0);
  Serial.printf("  pass: %s\n", same ? "MATCH" : "MISMATCH");
  return same ? 0 : 2;
}

// 把通行证写进卡：块 4 存口令，块 7（扇区尾）改成自定义密钥
static bool writePass() {
  MFRC522::MIFARE_Key k;
  memcpy(k.keyByte, FACTORY_KEY, 6);

  MFRC522::StatusCode st =
      rfid->PCD_Authenticate(MFRC522::PICC_CMD_MF_AUTH_KEY_A, PASS_BLOCK, &k, &rfid->uid);
  if (st != MFRC522::STATUS_OK) {
    Serial.printf("write: auth fail (%d)\n", (int)st);
    return false;
  }

  st = rfid->MIFARE_Write(PASS_BLOCK, (uint8_t *)PASS_TOKEN, 16);
  if (st != MFRC522::STATUS_OK) {
    Serial.printf("write: block %d fail (%d)\n", PASS_BLOCK, (int)st);
    return false;
  }

  uint8_t trailer[16];
  memset(trailer, 0, sizeof(trailer));
  memcpy(trailer, PASS_KEY_A, 6);
  trailer[6] = 0xFF;
  trailer[7] = 0x07;
  trailer[8] = 0x80;
  memcpy(trailer + 10, PASS_KEY_B, 6);

  st = rfid->MIFARE_Write(PASS_BLOCK + 3, trailer, 16);
  if (st != MFRC522::STATUS_OK) {
    Serial.printf("write: trailer fail (%d)\n", (int)st);
    return false;
  }
  return true;
}

// 写卡模式：60 秒内可以连写多张，每写一张把卡拿开再贴下一张
static void writeMode() {
  Serial.println("=== 写卡模式：把空白卡贴上去（60 秒内可连写多张） ===");
  blink(5, 120);

  int done = 0;
  String lastUid = "";
  uint32_t t0 = millis();

  while (millis() - t0 < 60000) {
    if (!rfid->PICC_IsNewCardPresent() || !rfid->PICC_ReadCardSerial()) {
      lastUid = "";          // 卡拿开了，允许写下一张
      delay(50);
      continue;
    }

    String u = bytesToHex(rfid->uid.uidByte, rfid->uid.size);
    u.toUpperCase();
    if (u == lastUid) {      // 同一张卡还贴着，别重复写
      rfid->PICC_HaltA();
      delay(100);
      continue;
    }
    lastUid = u;

    Serial.println("write card: " + u);
    bool ok = writePass();
    rfid->PICC_HaltA();
    rfid->PCD_StopCrypto1();

    if (ok) {
      done++;
      Serial.printf("*** WRITE OK (#%d) ***\n", done);
      blink(2, 600);
    } else {
      Serial.println("*** WRITE FAIL (卡片可能被锁) ***");
      blink(4, 300);
    }
    delay(300);
  }

  Serial.printf("写卡模式结束，共写入 %d 张\n", done);
  blink(done > 0 ? 2 : 7, 600);
}

// ==================== 主流程 ====================
void setup() {
  pinMode(LED_PIN, OUTPUT);
  led(false);
  pinMode(BTN_PIN, INPUT_PULLUP);

  Serial.begin(115200);
  uint32_t t = millis();
  while (!Serial && millis() - t < 1200) delay(10);
  delay(200);
  Serial.println("\n=== door card reader (autodetect) ===");

  uint8_t sck, miso, mosi, ss;
  bool ok = autoDetect(sck, miso, mosi, ss);
  if (!ok) {
    Serial.println("!! 没有找到能读到 RC522 的接线组合");
    blink(9, 90);   // 9 下快闪 = 探测失败
    // 继续跑，万一只是偶发
    SPI.begin(4, 5, 6, 7);
    rfid = new MFRC522(7, RST_PIN);
  } else {
    SPI.begin(sck, miso, mosi, ss);
    rfid = new MFRC522(ss, RST_PIN);
    blink(2, 600);   // 2 下慢闪 = 探测成功
  }
  rfid->PCD_Init();
  delay(100);
  Serial.printf("version now 0x%02X\n", rfid->PCD_ReadRegister(MFRC522::VersionReg));

  BLEDevice::init("door-reader");
  Serial.println("ready");
}

void loop() {
  // 按住 BOOT 2.5 秒 → 进入写卡模式
  if (digitalRead(BTN_PIN) == LOW) {
    uint32_t t0 = millis();
    while (digitalRead(BTN_PIN) == LOW && millis() - t0 < 3000) delay(20);
    if (millis() - t0 >= 2500) { writeMode(); delay(800); return; }
  }

  String uid = cardUid();
  if (uid.isEmpty()) { delay(60); return; }

  Serial.println("card: " + uid);
  blink(3, 150);   // 3 下 = 读到卡

  for (int i = 0; i < DENY_COUNT; i++) {
    if (uid.equalsIgnoreCase(DENY_UID[i])) {
      Serial.println("  -> 黑名单卡，拒绝");
      blink(3, 500);
      delay(800);
      return;
    }
  }

  if (!allowed(uid)) { blink(3, 500); delay(800); return; }

  int pr = checkPass();
  rfid->PCD_StopCrypto1();
  if (pr != 0) {
    Serial.println("  -> 卡内口令校验失败，不开锁");
    blink(pr == 2 ? 5 : 7, 200);
    delay(800);
    return;
  }

  if (!connectLock()) { blink(4, 250); delay(1500); return; }
  bool okk = doUnlock();
  disconnectLock();
  Serial.println(okk ? "*** UNLOCK OK ***" : "*** FAILED ***");
  blink(okk ? 6 : 4, 90);
  delay(1500);
}
