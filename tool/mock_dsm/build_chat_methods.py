#!/usr/bin/env python3
"""把**文档已确立**的 Chat 方法表灌进 `tool/mock_dsm/catalog.json`。

## 为什么需要它（第 45 轮发现的 B1/B2 真缺口）
`catalog.json` 里 **36 个 `SYNO.Chat.*` 全是 `methods:{}` + `methodsVerified:false`**
（来源是实况 `SYNO.API.Info` 快照，那个接口**只返回 path/minVersion/maxVersion，
不返回方法表**）。后果：

    mock 对 Chat **完全不校验方法名** —— 任何拼错的方法都会被当成合法请求接受，
    只会校验"API 存在 + 版本区间"。coverage 测试里"无 101/103/105"这句
    因此是**弱断言**：103 永远不会出现。

本机又**没有 Chat Server 的 SPK**（`/tmp/spk/export_*` 里没有 Chat），
所以拿不到权威 `.lib`。可用的权威替代是**反编译记录**：`docs/phase*-protocol.md`
与 `docs/phase9-server-settings.md` 逐条标了官方 Java 类/方法（如
`com/synology/dschat/data/AccountManager.java#fetchAdminSetting`）。

## 这个脚本干什么
1. 从 `docs/*.md` 抽 `SYNO.Chat.X/method` 与短写 `Post/method` 等引用；
2. 叠加 `KNOWN_VERSION_GATES`（有明确版本证据的方法）；
3. 写回 catalog：`methods: {版本: [方法…]}`、`methodsVerified: true`、
   `methodsSource: "docs-reverse-engineering"`，并在 `_note` 里**写明限制**。

## ⚠️ 诚实的限制（必须随数据一起看）
* 我们**没有**权威 `.lib`，所以**没有**真正的"哪个方法从哪个版本开始有"。
  `KNOWN_VERSION_GATES` 之外的方法被**复制到每个版本**。
  ⇒ 本表能拒绝**不存在的方法名**（这是现在的净收益），
  但**不能**拒绝"方法存在但版本不对"。
* `allowUser` 同样是空的 ⇒ **Chat 家族无法据此判 adminOnly**。
  已知例外：`SYNO.Chat.Admin.Setting` **不是** admin-only（名字骗人）——
  官方客户端用普通用户身份读它拿 `allow_encryption`/`allow_read_status`/
  `isSupportEditAllPost`（`docs/phase9-server-settings.md:17-19`）。

用法：`python3 tool/mock_dsm/build_chat_methods.py [--check]`
"""
from __future__ import annotations

import glob
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "tool" / "mock_dsm" / "catalog.json"

CHAT_APIS = {
    "SYNO.Chat.Admin.Setting", "SYNO.Chat.App", "SYNO.Chat.Archive",
    "SYNO.Chat.Bot", "SYNO.Chat.Channel", "SYNO.Chat.Channel.Anonymous",
    "SYNO.Chat.Channel.Chatbot", "SYNO.Chat.Channel.GuestUser",
    "SYNO.Chat.Channel.Hashtag", "SYNO.Chat.Channel.Hidden",
    "SYNO.Chat.Channel.Member", "SYNO.Chat.Channel.Named",
    "SYNO.Chat.Channel.Preference", "SYNO.Chat.Chatbot", "SYNO.Chat.External",
    "SYNO.Chat.Misc", "SYNO.Chat.Post", "SYNO.Chat.Post.Attachment",
    "SYNO.Chat.Post.File", "SYNO.Chat.Post.Hashtag", "SYNO.Chat.Post.Reaction",
    "SYNO.Chat.Post.Reminder", "SYNO.Chat.Post.Schedule", "SYNO.Chat.Post.Snippet",
    "SYNO.Chat.Post.Subscribe", "SYNO.Chat.Post.Vote", "SYNO.Chat.Sticker",
    "SYNO.Chat.User", "SYNO.Chat.User.Avatar", "SYNO.Chat.User.Preference",
    "SYNO.Chat.User.Status", "SYNO.Chat.Webhook.Broadcast",
    "SYNO.Chat.Webhook.BuiltIn", "SYNO.Chat.Webhook.Incoming",
    "SYNO.Chat.Webhook.Outgoing", "SYNO.Chat.Webhook.Slash",
}

#: 有**明确版本证据**的方法（出处见行尾注释）。这些只在 >= 该版本出现。
KNOWN_VERSION_GATES: dict[str, dict[str, int]] = {
    # `docs/phase4-protocol.md` §5.1：话题内置顶是 v2（v1 写的是 last_pin_at）
    "SYNO.Chat.Post": {"stick": 2, "unstick": 2},
    # `docs/phase9-server-settings.md` §1：候选 [4,3,1]；read_status 是 v3、
    # 可编辑任意消息是 v4
    "SYNO.Chat.Admin.Setting": {"get": 1},
    # `docs/phase6-protocol.md`：已读回执 `get_read_status` 是 v6+
    # （`api-method-level-gaps.md` 同口径）
}

#: 短写 → 全限定名的前缀（文档里常见 `Post/list`、`Channel/get`）
SHORT_PREFIX = {
    "Post": "SYNO.Chat.Post",
    "Channel": "SYNO.Chat.Channel",
    "User": "SYNO.Chat.User",
    "Sticker": "SYNO.Chat.Sticker",
    "Misc": "SYNO.Chat.Misc",
    "Archive": "SYNO.Chat.Archive",
    "Bot": "SYNO.Chat.Bot",
    "Chatbot": "SYNO.Chat.Chatbot",
    "External": "SYNO.Chat.External",
}


#: 合法方法名的形状。**必须严格** —— 宽松匹配会把散文里的 `v2`、`版本`、
#: `写死` 当成方法名，那比不校验更糟（mock 会接受 `Channel/v2` 这种伪方法）。
_METHOD_RE = re.compile(r"^[a-z][a-z0-9_]*$")
#: 已知会被误吞的散文/版本词（双保险）
_JUNK = {"v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "version"}


def _methods_from_run(run: str) -> list[str]:
    """把 `hide\\|show\\|hide_global` / `get set` / `list` 拆成方法名，滤掉垃圾。"""
    parts = re.split(r"[\s\\|/,、]+", run)
    out = []
    for p in parts:
        if not p or p in _JUNK or not _METHOD_RE.match(p):
            continue
        out.append(p)
    return out


def collect() -> dict[str, set[str]]:
    hits: dict[str, set[str]] = {a: set() for a in CHAT_APIS}
    files = sorted(glob.glob(str(ROOT / "docs" / "*.md"))) + sorted(
        glob.glob(str(ROOT / "docs" / "recheck" / "*.md"))
    )

    # ---- A) `docs/rewrite-plan.md` 的权威表：| API | 版本 | 方法… | ----
    # 这是**结构化**证据，优先且最可靠（比散文里捞强）。形如：
    #   | `SYNO.Chat.Channel.Preference` | 1 | get set |
    #   | `SYNO.Chat.User.Preference` | 1–3 | get set |
    table_re = re.compile(
        r"^\|\s*`?(SYNO\.Chat[A-Za-z0-9_.]*)`?\s*\|\s*([0-9–\-\s]+)\s*\|\s*([a-z_][^|]*?)\s*\|",
        re.M,
    )
    for f in files:
        text = Path(f).read_text(encoding="utf-8")
        for m in table_re.finditer(text):
            api = m.group(1)
            if api not in CHAT_APIS:
                continue
            for meth in _methods_from_run(m.group(3)):
                hits[api].add(meth)

    # ---- B) 明文 `SYNO.Chat.X/method…` 与短写 `Post/method…` ----
    sep = r"[\s\\|/,、]+"
    for f in files:
        text = Path(f).read_text(encoding="utf-8")
        for m in re.finditer(
            r"(SYNO\.Chat[A-Za-z0-9_.]*)\s*/\s*([a-z_][a-z0-9_]*(?:" + sep + r"[a-z_][a-z0-9_]*)*)",
            text,
        ):
            api = m.group(1)
            if api in CHAT_APIS:
                for meth in _methods_from_run(m.group(2)):
                    hits[api].add(meth)
        for m in re.finditer(
            r"`(?:Chat\.)?([A-Za-z]+(?:\.[A-Za-z]+)?)\s*/\s*([a-z_][a-z0-9_]*(?:" + sep + r"[a-z_][a-z0-9_]*)*)`",
            text,
        ):
            head = m.group(1)
            base, _, sub = head.partition(".")
            api = SHORT_PREFIX.get(base)
            if api is None:
                continue
            api = api + ("." + sub if sub else "")
            if api in CHAT_APIS:
                for meth in _methods_from_run(m.group(2)):
                    hits[api].add(meth)
    return hits


def build_methods(name: str, spec: dict, methods: set[str]) -> dict[str, list[str]]:
    """按版本铺开方法表。有 gate 的方法只在 >= gate 的版本出现。"""
    max_v = int(spec.get("maxVersion") or 1)
    gates = KNOWN_VERSION_GATES.get(name, {})
    out: dict[str, list[str]] = {}
    for v in range(1, max_v + 1):
        present = sorted(m for m in methods if gates.get(m, 1) <= v)
        if present:
            out[str(v)] = present
    return out


def main() -> int:
    check = "--check" in sys.argv
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    apis = catalog["apis"]
    hits = collect()

    changed = []
    for name in sorted(CHAT_APIS):
        spec = apis.get(name)
        if spec is None:
            print(f"  ⚠️ catalog 里没有 {name}，跳过", file=sys.stderr)
            continue
        methods = hits.get(name, set())
        table = build_methods(name, spec, methods)
        if not table:
            # 一条证据都没有 ⇒ **不假装能校验**，保持 methodsVerified=false
            continue
        spec["methods"] = table
        spec["methodsVerified"] = True
        spec["methodsSource"] = "docs-reverse-engineering"
        spec["_note"] = (
            "方法名来自反编译记录（docs/phase*-protocol.md、docs/phase9-server-settings.md），"
            "**不是** .lib —— 本机没有 Chat Server SPK。"
            "只能拒绝不存在的方法名，**不能**拒绝「方法存在但版本不对」"
            "（KNOWN_VERSION_GATES 之外的按「从 v1 就有」铺开到每个版本）。"
            "allowUser 仍为空 ⇒ 无法据此判 adminOnly。"
        )
        changed.append((name, len(methods), len(table)))

    catalog["chatMethodsAudited"] = "2026-09-23 (round 45)"
    if check:
        print(f"[check] {len(changed)} 个 Chat API 已有方法表")
        return 0
    CATALOG.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=1) + "\n", encoding="utf-8"
    )
    print(f"已更新 {len(changed)} 个 Chat API 的方法表：")
    for name, n, nv in changed:
        print(f"  {name}: {n} 个方法 / {nv} 个版本")
    done = {name for name, _, _ in changed}
    missing = sorted(a for a in CHAT_APIS if a not in done and a in apis)
    if missing:
        print(f"仍无方法表（保持不校验）：{missing}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
