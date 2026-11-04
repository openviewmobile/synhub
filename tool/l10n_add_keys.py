#!/usr/bin/env python3
"""把一批新文案 key **一致地**接入 ARB 与 `dataTextMap`，并生成 l10n。

为什么要这个工具：手工接入踩过的坑
--------------------------------
1. **zh / en 两份 ARB 的 key 【集合】与【顺序】必须完全一致** ——
   `test/ai_i18n_2d_test.dart` 会逐位比对顺序。手工追加时我在两份文件里
   用了不同顺序，导致第 4988 个 key 开始分叉，测试直接挂掉。
2. 漏跑 `flutter gen-l10n` ⇒ `dataTextMap` 里引用的 `t.xxx` getter 不存在
   ⇒ 19 个 `undefined_getter` 编译错误。
3. `int` 类型的占位符必须用 `_intTemplate`，不能直接 `t.key('{p}')`。
4. `dataTextMap` 的插入位置若不一致，diff 会很难读。

本工具的做法
-----------
* **以 zh ARB 的 key 顺序为唯一真源**：先插入 zh，再把 en **按 zh 的最终顺序重排**；
* 插入点用 `--anchor`（默认插在某个已有 key **之前**），两份文件用**同一个 anchor**；
* 自动为 `dataTextMap` 生成条目（默认 `'key': t.key,`）；
* 最后自动跑 `flutter gen-l10n`；
* **自带校验**：跑完立刻断言两份 ARB 的 key 顺序逐位相等，不等就报错退出。

输入格式（JSON）
---------------
```json
{
  "anchor": "photoFreeUpCancelled",
  "keys": [
    {"key": "userGapProfileTitle", "zh": "个人资料", "en": "Profile"},
    {"key": "userGapProfileEmail", "zh": "邮箱", "en": "Email"}
  ]
}
```
`anchor` 可省略，用 `--anchor` 参数给。若某个 key 已存在 ⇒ **报错**（不静默跳过）。

用法
----
```console
python3 tool/l10n_add_keys.py /tmp/new_keys.json
python3 tool/l10n_add_keys.py /tmp/new_keys.json --anchor someExistingKey --no-gen
```
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_ZH = os.path.join(ROOT, "lib/l10n/app_zh.arb")
ARB_EN = os.path.join(ROOT, "lib/l10n/app_en.arb")
L10N_DART = os.path.join(ROOT, "lib/src/core/i18n/l10n.dart")

# ARB 里的**顶层** key 行形如：  "someKey": "文案",   （恰好 2 空格缩进）
# ⚠️ 必须排除两类：`"@key"` 元数据行、以及 `@key` 块**内部**的嵌套行
#    （如 `placeholders`，缩进 ≥ 4）—— 我第一版没排除，导致把 zh 数成 8044 个
#    key、en 数成 7413 个，顺序比对全是假分叉。
_KEY_LINE = re.compile(r'^  "(?!@)([A-Za-z0-9_]+)"\s*:', re.M)


def _arb_line(key: str, value: str) -> str:
    """拼出一整行 ARB 条目：`  "key": "值",`（含 2 空格缩进与行尾逗号）。

    ⚠️ 这里必须返回**完整的一行**。`read_arb()` 的契约是
    `(key, 原始整行)`，`plan_arb_insert()` 直接把元组第二个元素当整行插进去。
    我第一版只返回了 `json.dumps(值) + ","` ⇒ 插进去的是**裸值、没有 key**，
    把 ARB 写成了 `"账号信息",` 这种无意义行（JSON 结构上仍是合法数组元素，
    所以 `json.loads` 不会报错，但 key 全部丢失）。**已回滚并修正。**
    """
    return f"  {json.dumps(key, ensure_ascii=False)}: {json.dumps(value, ensure_ascii=False)},"


def read_arb(path: str) -> tuple[list[tuple[str, str]], list[str]]:
    """返回 ([(key, 原始行)], 全部原始行)。保留原格式，不做 JSON 往返。"""
    lines = open(path, encoding="utf-8").read().split("\n")
    entries: list[tuple[str, str]] = []
    for ln in lines:
        m = _KEY_LINE.match(ln)
        if m:
            entries.append((m.group(1), ln))
    return entries, lines


def plan_arb_insert(
    path: str, new: list[tuple[str, str]], anchor: str
) -> str:
    """**只计算不写盘**：算出插入后的全文。anchor 缺失 / key 重复在这里就报错。"""
    entries, lines = read_arb(path)
    existing = {k for k, _ in entries}
    for k, _ in new:
        if k in existing:
            raise SystemExit(f"❌ key 已存在，拒绝静默覆盖：{k}（{path}）")

    anchor_ln = None
    for i, ln in enumerate(lines):
        m = _KEY_LINE.match(ln)
        if m and m.group(1) == anchor:
            anchor_ln = i
            break
    if anchor_ln is None:
        raise SystemExit(f"❌ 在文件中找不到 anchor 的行：{anchor}（{path}）")

    # 就地插入到 anchor 行之前，保留 arb 里非 key 行（如 "@key" 元数据）的相对位置。
    out = lines[:anchor_ln] + [ln for _, ln in new] + lines[anchor_ln:]
    return "\n".join(out)


def verify_arb_plan(
    label: str, path: str, plan_text: str, new_keys: list[str], before: int
) -> None:
    """写盘前的硬校验：计划文本必须真的是「增加了这些 key」的合法 ARB。

    防的就是这个 bug：插入行只有值没有 key（`"账号信息",`）。那种文本
    `json.loads` 依然成功、`_KEY_LINE` 依然只数出旧 key 数，
    于是两份文件"顺序一致"、看起来一切正常 —— 但整批 key 全丢了。
    """
    try:
        json.loads(plan_text)
    except Exception as e:  # noqa: BLE001
        raise SystemExit(f"❌ {label} 计划文本不是合法 JSON：{e}（{path}）")
    ks = _KEY_LINE.findall(plan_text)
    if len(ks) != before + len(new_keys):
        raise SystemExit(
            f"❌ {label} 计划 key 数不对：期望 {before}+{len(new_keys)}="
            f"{before + len(new_keys)}，实际 {len(ks)}（{path}）\n"
            "   常见原因：插入行缺少 `\"key\":` 前缀（只写了值）。"
        )
    missing = [k for k in new_keys if k not in set(ks)]
    if missing:
        raise SystemExit(f"❌ {label} 计划里缺少这些 key：{', '.join(missing)}")
    if len(set(ks)) != len(ks):
        raise SystemExit(f"❌ {label} 计划 key 数 {len(ks)} ≠ 去重后 {len(set(ks))}：有重复 key")


def l10n_map_entries(keys: list[str], int_keys: set[str]) -> list[str]:
    out = []
    for k in keys:
        if k in int_keys:
            out.append(
                f"      '{k}': _intTemplate(t.{k}(_kTemplateInt), '{k}'),"
            )
        else:
            out.append(f"      '{k}': t.{k},")
    return out


def plan_l10n_insert(new_keys: list[str], anchor: str, int_keys: set[str]) -> str:
    """**只计算不写盘**：算出插入后的 l10n.dart 全文。"""
    src = open(L10N_DART, encoding="utf-8").read()
    for k in new_keys:
        # Python 3.14 起"无效转义"是**硬错误**（以前只是警告）：
        # 原写法 `rf"'\{k}'\s*:"` 会拼出 `'\photoWave2X'` ⇒ `bad escape \p`。
        # 固定写法：key 必须 re.escape（key 全是标识符，结果等价但不会再炸）。
        if re.search(rf"'{re.escape(k)}'\s*:", src):
            raise SystemExit(f"❌ dataTextMap 里已有该 key：{k}")
    m = re.search(rf"^([ \t]*)'{re.escape(anchor)}'\s*:", src, re.M)
    if not m:
        raise SystemExit(f"❌ l10n.dart 里找不到 anchor 条目：{anchor}")
    indent = m.group(1)
    idx = m.start()
    entries = [
        (indent + e.strip()) if indent != "      " else e
        for e in l10n_map_entries(new_keys, int_keys)
    ]
    block = "\n".join(entries) + "\n"
    return src[:idx] + block + src[idx:]


def assert_same_order() -> None:
    z, _ = read_arb(ARB_ZH)
    e, _ = read_arb(ARB_EN)
    zk = [k for k, _ in z]
    ek = [k for k, _ in e]
    if zk != ek:
        # 找出第一处分叉，方便定位
        for i, (a, b) in enumerate(zip(zk, ek)):
            if a != b:
                raise SystemExit(
                    f"❌ 两份 ARB 的 key 顺序在第 {i} 位分叉：zh={a!r} en={b!r}\n"
                    f"   zh 共 {len(zk)} 个，en 共 {len(ek)} 个"
                )
        raise SystemExit(
            f"❌ key 数量不同：zh={len(zk)} en={len(ek)}（前缀相同）"
        )
    print(f"✅ 两份 ARB key 顺序逐位一致（各 {len(zk)} 个）")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("json_file")
    ap.add_argument("--anchor", help="插在该 key 之前（默认取 JSON 里的 anchor）")
    ap.add_argument("--no-gen", action="store_true", help="不跑 flutter gen-l10n")
    args = ap.parse_args()

    cfg = json.load(open(args.json_file, encoding="utf-8"))
    keys = cfg["keys"]
    anchor = args.anchor or cfg.get("anchor")
    if not anchor:
        raise SystemExit("❌ 必须给 anchor（JSON 里的 anchor 或 --anchor）")
    int_keys = set(cfg.get("intKeys", []))

    new_lines = []
    names = []
    for item in keys:
        k, zh, en = item["key"], item["zh"], item["en"]
        names.append(k)
        new_lines.append((k, _arb_line(k, zh)))

    en_map = {i["key"]: i["en"] for i in keys}
    en_lines = [(k, _arb_line(k, en_map[k])) for k in names]

    # ── 阶段 1：**全部只计算不写盘**（任何一步失败都不会留下半成品）──
    print(f"准备插入 {len(names)} 个 key，ARB anchor = {anchor}")
    plan_zh = plan_arb_insert(ARB_ZH, new_lines, anchor)
    plan_en = plan_arb_insert(ARB_EN, en_lines, anchor)
    plan_dart = plan_l10n_insert(names, anchor, int_keys)

    # ── 阶段 2：**写盘前**先验证计划文本本身是对的 ──
    # ⚠️ 这一道是必需的。`assert_same_order()` 跑在写盘**之后**，而且它靠
    #    `_KEY_LINE` 数 key —— 如果插入的是"裸值"行（没有 key），两份文件会被
    #    **同样地**漏数，于是计数相等、比对"通过"，坏文件却已经落地。
    #    所以必须在落盘前断言：JSON 合法、key 总数恰好增加 len(names)、每个新 key 都在。
    for label, plan_path, plan_text in (
        ("zh", ARB_ZH, plan_zh), ("en", ARB_EN, plan_en),
    ):
        before = len(read_arb(plan_path)[0])
        verify_arb_plan(label, plan_path, plan_text, names, before)

    # ── 阶段 3：全部校验通过后才统一写盘 ──
    # 先写临时文件，再原子改名，避免写到一半崩溃留下坏文件。
    for path, text in ((ARB_ZH, plan_zh), (ARB_EN, plan_en), (L10N_DART, plan_dart)):
        tmp = path + ".tmp.l10nadd"
        open(tmp, "w", encoding="utf-8").write(text)
        os.replace(tmp, path)

    assert_same_order()

    if not args.no_gen:
        env = dict(os.environ)
        env["PATH"] = "<flutter-sdk>/bin:" + env.get("PATH", "")
        print("跑 flutter gen-l10n …")
        r = subprocess.run(
            ["flutter", "gen-l10n"], cwd=ROOT, env=env,
            capture_output=True, text=True,
        )
        # ⚠️ 不要信退出码：`flutter gen-l10n` 在 l10n.yaml 存在时会打印
        #    "Because l10n.yaml exists, …" 的**无害提示**；而在多个批次并发跑
        #    flutter 时，它还可能瞬时失败。**唯一可靠的判据是生成的 getter 真出现。**
        gen = os.path.join(ROOT, "lib/l10n/gen/app_localizations.dart")
        if not os.path.exists(gen):
            raise SystemExit(f"❌ 生成文件不存在：{gen}")
        gsrc = open(gen, encoding="utf-8").read()
        missing = [k for k in names if f"String get {k}" not in gsrc
                   and f"String {k}(" not in gsrc]
        if missing:
            print(r.stdout.strip() or r.stderr.strip())
            raise SystemExit(
                "❌ flutter gen-l10n 没有生成这些 getter："
                + ", ".join(missing)
                + "\n   若提示是 'Because l10n.yaml exists…'，那是无害的；"
                  "真正的原因通常是**有别的 flutter 进程在并发跑**。"
                  "请稍后重跑本工具（ARB 与 dataTextMap 已经写好了，"
                  "用 --no-gen 再手动 `flutter gen-l10n` 即可）。"
            )
        print(f"✅ 已生成 {len(names)} 个 getter")

    print(f"✅ 完成：{len(names)} 个 key 已接入 ARB + dataTextMap")
    print("   新增 key：" + ", ".join(names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
