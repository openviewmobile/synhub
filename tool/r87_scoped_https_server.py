# r87-scoped 离线校验用的**最小 HTTPS 服务端**（本机回环 + 自签证书）。
#
# 只服务一个固定路径 `/x`，支持 Range（回 206 + Content-Range），不发任何
# 真实数据 —— 目的是让 `tool/r87_tls_repro.swift` 的 TLS 分支能在一个
# **零外网、零真 NAS** 的环境里被逐条断言。
import http.server
import ssl
import sys

PORT = int(sys.argv[1])
CERT = sys.argv[2]
KEY = sys.argv[3]
BODY = b"r87-scoped-check" * 64


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):  # 静音
        pass

    def do_GET(self):
        rng = self.headers.get("Range")
        start, end = 0, len(BODY) - 1
        partial = False
        if rng and rng.startswith("bytes="):
            spec = rng[len("bytes="):]
            a, _, b = spec.partition("-")
            if a:
                start = int(a)
                partial = True
            if b:
                end = min(int(b), len(BODY) - 1)
            if start >= len(BODY):
                self.send_response(416)
                self.end_headers()
                return
        payload = BODY[start:end + 1]
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        if partial:
            self.send_header(
                "Content-Range", f"bytes {start}-{end}/{len(BODY)}")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(CERT, KEY)
httpd = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
