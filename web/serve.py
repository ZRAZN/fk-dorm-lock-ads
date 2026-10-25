"""本地 HTTPS 服务器 —— 跑 Web Bluetooth 开锁页。

Web Bluetooth 要求页面必须是安全上下文（https 或 localhost），
所以手机上访问必须走 HTTPS。这里用自签证书起一个，浏览器报警告点「继续前往」即可。

用法：
    python serve.py            # 默认 8443 端口
    python serve.py 9443       # 指定端口

首次运行会自动生成 cert.pem / key.pem（90 天有效，含本机局域网 IP 的 SAN）。
生成方式优先用 cryptography 库，没有就回退到系统 openssl 命令。
"""
import http.server
import os
import socket
import ssl
import subprocess
import sys
import datetime

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8443
ROOT = os.path.dirname(os.path.abspath(__file__))
CERT = os.path.join(ROOT, "cert.pem")
KEY = os.path.join(ROOT, "key.pem")


def local_ips():
    ips = {"127.0.0.1"}
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ips.add(s.getsockname()[0])
        s.close()
    except Exception:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ips.add(info[4][0])
    except Exception:
        pass
    return sorted(i for i in ips if not i.startswith("169.254."))


def gen_with_cryptography(ips):
    from cryptography import x509
    from cryptography.x509.oid import NameOID
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "dormlock.local")])
    san = [x509.DNSName("localhost")] + [x509.IPAddress(__import__("ipaddress").ip_address(i)) for i in ips]
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=90))
        .add_extension(x509.SubjectAlternativeName(san), critical=False)
        .sign(key, hashes.SHA256())
    )
    with open(KEY, "wb") as f:
        f.write(key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption(),
        ))
    with open(CERT, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))


def gen_with_openssl(ips):
    san = ",".join(["DNS:localhost"] + [f"IP:{i}" for i in ips])
    subprocess.run(
        [
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", KEY, "-out", CERT, "-days", "90",
            "-subj", "/CN=dormlock.local",
            "-addext", f"subjectAltName={san}",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def ensure_cert():
    if os.path.exists(CERT) and os.path.exists(KEY):
        return
    ips = local_ips()
    print("首次运行，正在生成自签证书 …")
    try:
        gen_with_cryptography(ips)
        print("  已用 cryptography 生成 cert.pem / key.pem（90 天）")
    except ImportError:
        try:
            gen_with_openssl(ips)
            print("  已用 openssl 生成 cert.pem / key.pem（90 天）")
        except Exception as e:
            print("生成证书失败：", e)
            print("请先安装任一依赖：pip install cryptography   或   安装 openssl")
            sys.exit(1)


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        print(f"[{self.address_string()}] {fmt % args}", flush=True)


def main():
    ensure_cert()
    httpd = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT, KEY)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)

    print("=" * 56)
    for ip in local_ips():
        print(f"  手机打开:  https://{ip}:{PORT}/")
    print(f"  本机打开:  https://127.0.0.1:{PORT}/")
    print("=" * 56)
    print("  证书警告 → 点「高级」→「继续前往」")
    print("  iOS 请用 Bluefy，Safari 不支持 Web Bluetooth")
    print("=" * 56, flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
