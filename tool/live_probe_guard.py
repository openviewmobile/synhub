#!/usr/bin/env python3
"""§5.1 变更动词**强制闸门** —— 给"真机只读探针"用。

## 为什么会有这个文件

2026-09-23 第 31 轮，我在用"候选方法名扫描"判定 `SYNO.Personal.*` 的方法存在性时，
**把 `delete` 这种变更动词发给了用户的真 NAS**，
命中 `SYNO.Personal.Profile.Photo / delete` → `{"success":true}`
—— **可能删掉了用户的 DSM 个人资料照片**（详见
`docs/incident-2026-09-23-profile-photo-delete.md`）。

根因之一是：**§5.1 只写在文档里，探针脚本里没有闸门。**
这个文件把那条规定变成**代码**：任何发往**真实 host** 的请求，
只要方法名命中黑名单，**直接拒绝发送**。

## 用法

    from live_probe_guard import guarded_get

    body = guarded_get(base, path, params, sid=sid)   # 命中黑名单会抛 ProhibitedMethod

或者命令行自测：

    python3 tool/live_probe_guard.py --selftest

## 判定规则（刻意保守）

* **目标是不是"真机"**：host 是 `localhost` / `127.0.0.1` / `::1` → 放行（那是 mock）；
  其余一律当**真机**处理。
* **方法名**：大小写不敏感；命中黑名单的**完整词**或前缀即拒绝。
  黑名单与 `§5.1` 文档逐字一致。
* 另外拒绝：**没有显式给 method** 的请求（方法名空 ⇒ 无法判定 ⇒ 不放行）。

宁可误拦只读请求（让人显式豁免），也不放过一次 `delete`。
"""

from __future__ import annotations

import argparse
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

# ── §5.1 变更动词黑名单（与文档逐字一致）──────────────────────────────
MUTATING_VERBS: frozenset[str] = frozenset(
    {
        "set",
        "delete",
        "create",
        "update",
        "add",
        "remove",
        "clear",
        "stop",
        "start",
        "move",
        "copy",
        "upload",
        "cancel",
        "rename",
        "replace",
        "edit",
        "apply",
        "restore",
        "save",
        "avoid",
        "init",
        "import",
        "export",
        "refresh",
    }
)

# 明确**不在**黑名单里、但容易被误认为是的（写下来防止"顺手加进去"）：
#   `download`  —— §5.1 原文明确排除
#   `get` / `list` / `getinfo` / `status` / `stat` / `check` / `query` —— 只读
NOT_MUTATING: frozenset[str] = frozenset({"download"})

LOCAL_HOSTS: frozenset[str] = frozenset({"localhost", "127.0.0.1", "::1", "0.0.0.0"})


class ProhibitedMethod(RuntimeError):
    """命中 §5.1 黑名单 —— **请求没有被发出**。"""


class MissingMethod(RuntimeError):
    """没有显式给 method ⇒ 无法判定是否安全 ⇒ 不放行。"""


def is_local(base: str) -> bool:
    """base 指向本机（mock）吗？"""
    host = urllib.parse.urlparse(base).hostname or ""
    return host in LOCAL_HOSTS


def _method_matches(name: str) -> str | None:
    """返回命中的黑名单词（没有则 None）。大小写不敏感，支持 `xxx_delete` 这类。"""
    low = name.lower()
    for v in MUTATING_VERBS:
        if low == v or low.startswith(v + "_") or low.endswith("_" + v):
            return v
    return None


def check(base: str, params: dict) -> None:
    """在发送**之前**调用。真机 + 变更动词 ⇒ 抛 [ProhibitedMethod]。"""
    if is_local(base):
        return  # mock，随便打
    raw = params.get("method")
    if raw is None or str(raw).strip() == "":
        raise MissingMethod(
            f"对真机 {base} 的请求没有显式 method ⇒ 无法判定安全性，拒绝发送。"
            f"（params={params!r}）"
        )
    name = str(raw)
    if name.lower() in NOT_MUTATING:
        return
    hit = _method_matches(name)
    if hit:
        raise ProhibitedMethod(
            f"§5.1 拦截：对真机 {base} 调用变更动词 `{name}`（命中 `{hit}`）。\n"
            f"  api={params.get('api')!r} method={name!r} version={params.get('version')!r}\n"
            f"  如果这确实是**你想要的用户动作**（不是探针扫描），请改走 Mock Server；\n"
            f"  详见 docs/incident-2026-09-23-profile-photo-delete.md"
        )


_SSL_CTX = ssl._create_unverified_context()  # noqa: SLF001 —— 自签名 NAS 证书


def guarded_get(
    base: str,
    path: str,
    params: dict,
    *,
    timeout: int = 20,
    allow_prohibited: bool = False,
) -> tuple[int, bytes]:
    """带闸门的 GET。返回 `(status, body)`。

    `allow_prohibited=True` 是**显式豁免**，只应存在于"用户明确授权的写操作"里，
    探针脚本**永不**使用。
    """
    if not allow_prohibited:
        check(base, params)
    q = dict(params)
    url = f"{base}{path}"
    if q:
        url += ("&" if "?" in path else "?") + urllib.parse.urlencode(q, doseq=True)
    with urllib.request.urlopen(url, timeout=timeout, context=_SSL_CTX) as r:
        return r.status, r.read()


# ── 自测 ────────────────────────────────────────────────────────────────
def _selftest() -> int:
    ok = True
    cases: list[tuple[str, dict, bool, str]] = [
        # (base, params, 应该被放行?, 说明)
        ("https://nas.example.com:5001", {"api": "SYNO.X", "method": "get",
                                         "version": 1}, True, "真机只读 ⇒ 放行"),
        ("https://nas.example.com:5001", {"api": "SYNO.X", "method": "list",
                                         "version": 1}, True, "真机 list ⇒ 放行"),
        ("https://nas.example.com:5001", {"api": "SYNO.Personal.Profile.Photo",
                                         "method": "delete", "version": 1},
         False, "★ 就是它：真机 delete ⇒ **必须拦**"),
        ("https://nas.example.com:5001", {"api": "SYNO.X", "method": "set",
                                         "version": 1}, False, "真机 set ⇒ 拦"),
        ("https://nas.example.com:5001", {"api": "SYNO.X", "method": "upload",
                                         "version": 1}, False, "真机 upload ⇒ 拦"),
        ("https://nas.example.com:5001", {"api": "SYNO.X", "method": "clear_cache",
                                         "version": 1}, False, "`clear_cache` ⇒ 拦（前缀命中）"),
        ("https://nas.example.com:5001", {"api": "SYNO.X", "method": "download",
                                         "version": 1}, True,
         "`download` 不在黑名单（§5.1 明确排除）⇒ 放行"),
        ("https://nas.example.com:5001", {"api": "SYNO.X", "version": 1},
         False, "真机 + 没有 method ⇒ 拦（无法判定就不放行）"),
        ("http://127.0.0.1:18099", {"api": "SYNO.X", "method": "delete",
                                    "version": 1}, True, "mock（本机）⇒ 放行"),
        ("http://localhost:18099", {"api": "SYNO.X", "method": "create",
                                    "version": 1}, True, "mock ⇒ 放行"),
    ]
    for base, params, should_pass, desc in cases:
        try:
            check(base, params)
            passed = True
            why = ""
        except (ProhibitedMethod, MissingMethod) as e:
            passed = False
            why = type(e).__name__
        mark = "✅" if passed == should_pass else "❌"
        if passed != should_pass:
            ok = False
        verdict = "放行" if passed else f"拦截({why})"
        print(f"{mark} {desc:56s} → {verdict}")
    print()
    print("自测" + ("通过 ✅" if ok else "**失败** ❌"))
    return 0 if ok else 1


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="§5.1 变更动词强制闸门")
    ap.add_argument("--selftest", action="store_true", help="跑内置自测")
    ap.add_argument("--check", nargs=2, metavar=("BASE", "METHOD"),
                    help="手工判定 base + method 是否放行")
    a = ap.parse_args(argv)
    if a.selftest:
        return _selftest()
    if a.check:
        try:
            check(a.check[0], {"api": "<cli>", "method": a.check[1]})
            print("放行")
            return 0
        except (ProhibitedMethod, MissingMethod) as e:
            print(f"拦截：{e}")
            return 1
    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
