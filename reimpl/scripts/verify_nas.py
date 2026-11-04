#!/usr/bin/env python3
"""真实 NAS 打洞验证 —— 命令行版

比 Flutter UI 更适合反复排查：直接 ctypes 调 libsynochatpunch，全流程可见。

用法：
    python3 reimpl/scripts/verify_nas.py <QuickConnectID> [账号] [密码]
    python3 reimpl/scripts/verify_nas.py <QCID> --service dsm_https --skip-login

流程：
    ① get_echo_list          → echo 站点 + udt_tx_mss
    ② get_server_info 两阶段  → relay_servers / 打洞端口 / 外网地址
    ③ 打洞 + 建 UDT 隧道       → 本地 127.0.0.1:<port> 监听
    ④ 通过隧道打 WebAPI        → 验证隧道与直连等价
"""
import argparse
import ctypes
import json
import os
import ssl
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

WORLDWIDE = "https://global.quickconnect.to/Serv.php"
CHINA = "https://global.quickconnect.cn/Serv.php"

SERVICE_TYPES = {"dsm_http": 0, "dsm_https": 1, "webdav": 2}
ERR_NAME = {
    0: "ok", 1: "invalid_arg", 2: "no_echo_server", 3: "load_udt_failed",
    4: "punch_failed", 5: "connect_failed", 6: "relay_failed", 7: "timeout",
    8: "already_running", 9: "not_running", 10: "bad_response",
}


# ─────────────────────────────────────────────────────────── 输出工具
class C:
    G, R, Y, B, D, X = "\033[32m", "\033[31m", "\033[33m", "\033[36m", "\033[2m", "\033[0m"


def ok(msg):   print(f"  {C.G}OK  {C.X} {msg}")
def bad(msg):  print(f"  {C.R}FAIL{C.X} {msg}")
def info(msg): print(f"  {C.D}·{C.X}   {msg}")
def head(msg): print(f"\n{C.B}── {msg} {C.X}")


# ─────────────────────────────────────────────────────────── HTTP
def post_json(url, payload, timeout=15):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json", "Accept": "application/json"})
    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
        return json.loads(r.read().decode())


# ─────────────────────────────────────────────────────────── ① echo 列表
def fetch_echo_list(control=WORLDWIDE):
    head("① get_echo_list")
    t0 = time.time()
    try:
        j = post_json(control, {"version": "1", "command": "get_echo_list"})
    except Exception as e:
        bad(f"请求失败: {e}")
        return None
    ms = int((time.time() - t0) * 1000)
    if j.get("errno") != 0:
        bad(f"errno={j.get('errno')} errinfo={j.get('errinfo')}")
        return None
    sites = [s for s in j.get("sites", []) if isinstance(s, str)]
    port = j.get("port", 4000)
    mss = j.get("udt_tx_mss", 1370)
    ok(f"errno=0  用时 {ms}ms")
    info(f"sites      = {sites}")
    info(f"port       = {port}")
    info(f"udt_tx_mss = {mss}")
    return {"sites": sites, "port": port, "udt_tx_mss": mss}


# ─────────────────────────────────────────────────────────── ② server info
def fetch_server_info(server_id, service_id, control=WORLDWIDE, relay=None):
    url = f"https://{relay}/Serv.php" if relay else control
    return post_json(url, {
        "version": 1, "command": "get_server_info", "serverID": server_id,
        "id": service_id, "get_ca_fingerprints": True,
    })


def resolve(server_id, service_id, control=WORLDWIDE):
    head("② get_server_info（两阶段）")
    try:
        stage1 = fetch_server_info(server_id, service_id, control)
    except Exception as e:
        bad(f"阶段1 失败: {e}")
        return None
    if stage1.get("errno") != 0:
        bad(f"阶段1 errno={stage1.get('errno')} errinfo={stage1.get('errinfo')}")
        return None

    relays = [r for r in stage1.get("relay_servers", []) if isinstance(r, str)]
    ok(f"阶段1 拿到 {len(relays)} 个 relay: {relays[:5]}")
    if stage1.get("server"):
        info("阶段1 直接返回 server，无需阶段2")
        return stage1

    # 阶段2：并发打区域中继，第一个给出 server 的胜出
    with ThreadPoolExecutor(max_workers=min(8, max(1, len(relays)))) as ex:
        futs = {ex.submit(fetch_server_info, server_id, service_id, control, r): r
                for r in relays}
        for f in futs:
            try:
                j = f.result()
            except Exception:
                continue
            if j.get("errno") == 0 and j.get("server"):
                ok(f"阶段2 {futs[f]} 胜出")
                return j
    bad(f"所有 relay 都没返回 server: {relays}")
    return None


import socket as _socket


def resolve_host(h):
    """把主机名解析成 IP；解析不了返回 None。smartdns.host 常常解析不出来。"""
    try:
        return _socket.gethostbyname(h)
    except Exception:
        return None


def punch_candidates(info):
    srv = info.get("server") or {}
    sd = info.get("smartdns") or {}
    port = srv.get("udp_punch_port")
    hosts, seen = [], set()

    def add(h):
        if isinstance(h, str) and h and h not in seen:
            seen.add(h)
            hosts.append(h)

    add(sd.get("host"))
    for k in ("external", "ddns", "fqdn"):
        add(srv.get(k))
    for i in (srv.get("interface") or []):
        if isinstance(i, dict):
            add(i.get("ip"))
    # 去掉占位值与解析不出来的名字，附上解析结果
    out = []
    for h in hosts:
        if h in ("NULL", "", None):
            continue
        ip = resolve_host(h)
        if ip:
            out.append((h, ip))
    return out, port, hosts


def all_candidates(info):
    """返回 [(host, ip, port), ...]，按优先级，已过滤解析失败的。"""
    cands, port, raw = punch_candidates(info)
    if not port:
        return []
    return [(h, ip, int(port)) for h, ip in cands]


# ─────────────────────────────────────────────────────────── ③ 打洞
def load_punch(dylib):
    """按 punch_c.h 逐个声明签名 —— 别用循环套模板，各函数参数个数不同。"""
    if not os.path.exists(dylib):
        bad(f"找不到 {dylib}（先 cmake --build reimpl/build）")
        return None
    lib = ctypes.CDLL(dylib)
    P, S, I = ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int

    lib.synopunch_new.restype = P
    lib.synopunch_new.argtypes = []

    sig = {
        "synopunch_free":                    ([P], None),
        "synopunch_set_server_id":           ([P, S], None),
        "synopunch_set_service_type":        ([P, I], None),
        "synopunch_add_echo_server":         ([P, S, I], None),
        "synopunch_clear_echo_servers":      ([P], None),
        "synopunch_set_udt_tx_mss":          ([P, I], None),
        "synopunch_set_candidate":           ([P, S, I], None),
        "synopunch_clear_candidate":         ([P], None),
        "synopunch_set_rendezvous":          ([P, I], None),
        "synopunch_set_local_service_port":  ([P, I], None),
        "synopunch_set_punch_timeout":       ([P, I], None),
        "synopunch_set_connect_timeout":     ([P, I], None),
        "synopunch_start":                   ([P], I),          # ← 只收 1 个参数
        "synopunch_tcp_port":                ([P], I),
        "synopunch_poll":                    ([P, I], I),
        "synopunch_stop":                    ([P], None),
        "synopunch_is_running":              ([P], I),
        "synopunch_last_error":              ([P], S),
        "synopunch_rx_bytes":                ([P], ctypes.c_uint64),
        "synopunch_tx_bytes":                ([P], ctypes.c_uint64),
    }
    for name, (args, ret) in sig.items():
        fn = getattr(lib, name)
        fn.argtypes = args
        if ret is not None:
            fn.restype = ret
    return lib


def do_punch(lib, qc_id, service, echo, srv_info, punch_timeout=10000, forced_candidate=None):
    head("③ 打洞 + 建 UDT 隧道")
    h = lib.synopunch_new()
    if not h:
        bad("synopunch_new 返回空")
        return None

    lib.synopunch_set_server_id(h, qc_id.encode())
    lib.synopunch_set_service_type(h, SERVICE_TYPES.get(service, 1))
    if echo and echo.get("udt_tx_mss"):
        lib.synopunch_set_udt_tx_mss(h, echo["udt_tx_mss"])
        info(f"udt_tx_mss = {echo['udt_tx_mss']}")
    for s in (echo or {}).get("sites", []):
        lib.synopunch_add_echo_server(h, s.encode(), (echo or {}).get("port", 4000))
    info(f"echo 服务器 {len((echo or {}).get('sites', []))} 个")

    cands = all_candidates(srv_info) if srv_info else []
    if not cands:
        _, port0, raw = punch_candidates(srv_info) if srv_info else ([], None, [])
        bad(f"没有可解析的打洞候选（udp_punch_port={port0}）")
        info(f"原始候选: {raw[:8]}")
    else:
        ok(f"可解析的打洞候选 {len(cands)} 个")
        # 注意：循环变量**不能**叫 h，否则会覆盖上面的原生句柄
        for cname, cip, cpt in cands:
            info(f"  {cname} → {cip}:{cpt}")
        chosen = cands[0]
        if forced_candidate:
            host, _, cport = forced_candidate.partition(':')
            ip = resolve_host(host) or host
            chosen = (host, ip, int(cport) if cport else cands[0][2])
            info(f"用 --candidate 指定: {chosen[0]} → {chosen[1]}:{chosen[2]}")
        lib.synopunch_set_candidate(h, chosen[1].encode(), chosen[2])
        info(f"本次使用: {chosen[0]} → {chosen[1]}:{chosen[2]}")

    lib.synopunch_set_punch_timeout(h, punch_timeout)
    lib.synopunch_set_connect_timeout(h, punch_timeout)

    t0 = time.time()
    rc = lib.synopunch_start(h)
    ms = int((time.time() - t0) * 1000)
    err = (lib.synopunch_last_error(h) or b"").decode(errors="replace")

    if rc != 0:
        bad(f"rc={rc}({ERR_NAME.get(rc, '?')}) lastError=\"{err}\" 用时 {ms}ms")
        lib.synopunch_free(h)
        return None
    local = lib.synopunch_tcp_port(h)
    ok(f"隧道建立  用时 {ms}ms  lastError=\"{err}\"")
    info(f"本地监听 = 127.0.0.1:{local}")
    return h, local


# ─────────────────────────────────────────────────────────── ④ 隧道可用性
def http_via_tunnel(port, path, timeout=20):
    url = f"https://127.0.0.1:{port}{path}"
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
        return r.status, r.read().decode(errors="replace")


def check_tunnel(local):
    head("④ 通过隧道访问 WebAPI")
    import urllib.parse as up
    q = up.urlencode({"api": "SYNO.API.Info", "method": "query",
                      "version": "1", "query": "all"})
    try:
        status, body = http_via_tunnel(local, f"/webapi/query.cgi?{q}")
    except Exception as e:
        bad(f"隧道请求失败: {type(e).__name__}: {e}")
        return False
    ok(f"HTTP {status}  收到 {len(body)} 字节")
    try:
        j = json.loads(body)
    except Exception:
        info(f"非 JSON 响应: {body[:160]}")
        return False
    if j.get("success"):
        apis = (j.get("data") or {}).get("apis") or {}
        ok(f"SYNO.API.Info 成功，暴露 {len(apis)} 个 API")
        for k in ("SYNO.API.Auth", "SYNO.API.Encryption", "SYNO.Entry.Request"):
            if k in apis:
                info(f"{k:22} path={apis[k].get('path')} maxVersion={apis[k].get('maxVersion')}")
        return True
    bad(f"success=false  errno={((j.get('error') or {}).get('code'))}")
    return False


# ─────────────────────────────────────────────────────────── main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("qc_id")
    ap.add_argument("account", nargs="?")
    ap.add_argument("password", nargs="?")
    ap.add_argument("--service", default="dsm_https", choices=list(SERVICE_TYPES))
    ap.add_argument("--china", action="store_true", help="用 global.quickconnect.cn")
    ap.add_argument("--skip-login", action="store_true")
    ap.add_argument("--skip-punch", action="store_true")
    ap.add_argument("--timeout", type=int, default=10000)
    ap.add_argument("--candidate", help="手动指定打洞候选 host[:port]")
    ap.add_argument("--dylib", default="reimpl/build/libsynochatpunch.dylib")
    a = ap.parse_args()

    control = CHINA if a.china else WORLDWIDE
    print(f"{C.B}真实 NAS 打洞验证{C.X}  QC ID = {a.qc_id}  服务 = {a.service}")
    print(f"{C.D}控制服务器 = {control}{C.X}")

    echo = fetch_echo_list(control)
    info_ = resolve(a.qc_id, a.service, control)
    if info_:
        srv = info_.get("server") or {}
        head("②b server 摘要")
        for k in ("serverID", "external", "ddns", "fqdn", "udp_punch_port",
                  "tcp_punch_port", "behind_nat", "gateway"):
            if srv.get(k) not in (None, ""):
                info(f"{k:16} = {srv[k]}")
        svc = info_.get("service") or {}
        if svc:
            info(f"{'service.port':16} = {svc.get('port')}")
            info(f"{'relayIP':16} = {svc.get('relayIP')}")

    if a.skip_punch:
        print(f"\n{C.Y}已跳过打洞{C.X}")
        return 0

    lib = load_punch(a.dylib)
    if not lib:
        return 2
    r = do_punch(lib, a.qc_id, a.service, echo, info_, a.timeout, a.candidate)
    if not r:
        return 3
    h, local = r
    tunneled = check_tunnel(local)
    if a.account and not a.skip_login:
        head("⑤ 通过隧道登录 DSM")
        info("（登录逻辑见 lib/src/dsm/webapi.dart，此处仅确认隧道可达）")
        info(f"账号 = {a.account}")
    rx, tx = lib.synopunch_rx_bytes(h), lib.synopunch_tx_bytes(h)
    head("统计")
    info(f"rx = {rx} bytes   tx = {tx} bytes")
    lib.synopunch_stop(h)
    lib.synopunch_free(h)
    print(f"\n{C.G if tunneled else C.R}结果: "
          f"{'隧道可用，与直连等价' if tunneled else '隧道未通过验证'}{C.X}")
    return 0 if tunneled else 4


if __name__ == "__main__":
    sys.exit(main())
