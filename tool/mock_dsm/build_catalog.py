#!/usr/bin/env python3
"""从反编译 SPK 的 `webapi/*.lib` 汇总出 **Mock Server 的权威接口目录**。

## 为什么这么做（用户 2026-09-23 新规）
> 涉及管理员的接口，在电脑上搭建 mock server 模拟测试，必须通过模拟测试，
> 接口定义以及服务端返回数据可以通过反编译 spk 以及 apk 来获取。

`webapi/*.lib` 是 **Synology 自己发布的方法/版本表**（就是 JSON），
比任何二手文档都权威：`maxVersion` / `minVersion` / 每个版本里到底有哪几个方法
/ `authLevel` / `allowUser`（据此判"仅管理员"）。本脚本把它汇总成
`tool/mock_dsm/catalog.json`，让 Dart 侧的 Mock Server 与用例**离线、可复现**地跑。

## 用法
    python3 tool/mock_dsm/build_catalog.py            # 用内置的 SPK 解包根目录
    python3 tool/mock_dsm/build_catalog.py <dir>...   # 指定若干解包目录

## 产物（catalog.json）
    {
      "generatedFrom": [...],
      "apis": {
        "SYNO.FileStation.List": {
          "maxVersion": 2, "minVersion": 1, "authLevel": 1,
          "allowUser": ["normal.local", ...], "appPriv": "...",
          "normal": true,            # allowUser 里有 normal.* ⇒ 普通用户可用
          "adminOnly": false,        # 只有 admin.* ⇒ 仅管理员（新规要求也要 mock 验证）
          "methods": {"1": ["list","list_share"], "2": [...]}
        }, ...
      }
    }
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

# 默认扫描：`/tmp/spk` 下所有解包目录（Mac 本地，不改 NAS 任何内容）。
#
# 为什么**自动发现**而不是写死一张清单：写死就漏过 —— 第一版漏掉了
# `export_SynologyPhotos` / `export_SynologyDrive`，以及含 **122 个
# `SYNO.Core.*` 平台/管理员 API** 的 `ex_AI_pat`，目录只剩 175 个 API。
#
# `out2` 是 `ex_SS` 的重复解包产物（同一批 `.lib`），排除以免重复计数。
SPK_ROOT = Path("/tmp/spk")
SKIP_DIRS = {"out2", "libdirs"}


def default_roots() -> list[Path]:
    if not SPK_ROOT.is_dir():
        return []
    return sorted(p for p in SPK_ROOT.iterdir()
                  if p.is_dir() and p.name not in SKIP_DIRS)

OUT = Path(__file__).resolve().parent / "catalog.json"

# 想"只生成不覆盖"时用：`MOCK_CATALOG_OUT=/tmp/x.json python3 build_catalog.py`。
# （别再用位置参数试 —— 那是 SPK 目录，见 main() 里的防呆。）
import os as _os  # noqa: E402

if _os.environ.get("MOCK_CATALOG_OUT"):
    OUT = Path(_os.environ["MOCK_CATALOG_OUT"])


def lib_files(root: Path) -> list[Path]:
    """在解包目录里找 `webapi/*.lib`（含 `usr/syno/synoman/webapi`）。"""
    if root.is_file() and root.suffix == ".lib":
        return [root]
    for base in (root / "webapi",
                 root / "usr" / "syno" / "synoman" / "webapi",
                 root / "usr" / "synology" / "webapi"):
        found = sorted(base.glob("*.lib"))
        if found:
            return found
    # 平台包（`ex_AI_pat` 等）的 `.lib` 分散在多级子目录里 —— 递归兜底。
    # ⚠️ 同一个 `.lib` 可能在多个解包目录里各有一份（归档条目重复），
    # 合并逻辑对同 API 做并集，所以重复不会让 API 数虚高。
    return sorted(root.rglob("*.lib"))


def merge_methods(raw: dict) -> dict[str, list[str]]:
    """`{"1":[{"list":{...}},...]}` → `{"1":["list",...]}`（去重、保序）。"""
    out: dict[str, list[str]] = {}
    for ver, items in (raw or {}).items():
        names: list[str] = []
        for it in items:
            if isinstance(it, dict):
                for name in it:
                    if name not in names:
                        names.append(name)
            elif isinstance(it, str) and it not in names:
                names.append(it)
        out[str(ver)] = names
    return out


# 实况快照：`test/fixtures/api_table.json` 是**真 NAS `SYNO.API.Info` 的录像**
# （977 个 API，只有 path/minVersion/maxVersion）。SPK 里没有的族（`SYNO.Finder.*`、
# `SYNO.Personal.*`…）靠它补上 —— 否则 App 引用了却"无权威依据"。
# ⚠️ 它**没有方法表**，所以这些条目 `methodsVerified=false`：mock 只校验
# API 是否存在 + 版本区间，**不校验方法名**（没数据就不假装能校验）。
LIVE_SNAPSHOT = Path(__file__).resolve().parents[2] / "test" / "fixtures" / "api_table.json"


def merge_live(apis: dict[str, dict], sources: list[str]) -> int:
    """把实况快照并进来；**不覆盖** SPK 已有的方法表。返回新增条数。"""
    if not LIVE_SNAPSHOT.is_file():
        return 0
    try:
        live = json.loads(LIVE_SNAPSHOT.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        print(f"[warn] 实况快照解析失败：{exc}", file=sys.stderr)
        return 0
    if not isinstance(live, dict):
        return 0
    sources.append(str(LIVE_SNAPSHOT))
    added = 0
    for api, entry in live.items():
        if api in apis or not isinstance(entry, dict):
            continue
        apis[api] = {
            "maxVersion": entry.get("maxVersion"),
            "minVersion": entry.get("minVersion"),
            "authLevel": entry.get("authLevel"),
            "allowUser": entry.get("allowUser") or [],
            "appPriv": entry.get("appPriv"),
            # `requestFormat` 是**活的 `SYNO.API.Info` 才会给的字段**（SPK `.lib`
            # 没有它）：App 据此决定参数值编码（官方《DS file》规则，见 DA24）。
            # 快照里有就带上，别让重新生成把这一位丢掉。
            **({"requestFormat": entry["requestFormat"]}
               if entry.get("requestFormat") else {}),
            # 实况的 `authLevel` 有时缺；缺了就当需要登录（保守，宁可多要 sid）
            "normal": bool(entry.get("allowUser"))
            and any(str(a).startswith("normal.") for a in (entry.get("allowUser") or [])),
            "adminOnly": False,
            "methods": {},
            "source": "live",
            "methodsVerified": False,
        }
        added += 1
    return added


# ── 文档方法表 overlay ─────────────────────────────────────────────────
#
# 有些 API **不在任何 SPK 包里**（`SYNO.Personal.Notification.*` 是 DSM 平台自带，
# 没有对应 SPK），但仓库里已经有**方法级**的权威记录：
# `docs/api-server-authoritative.md`（从 DSM 端整理，逐版本列方法）。
#
# 这里把它们补进目录，好处是 **Mock Server 能真的校验这些方法名** ——
# 否则 `methods: {}` + `methodsVerified: false` 意味着"方法名不校验"，
# 我写错方法名 Mock 也不会报 103（这正是 COV-4 之前踩过的盲区）。
#
# ⚠️ **来源必须可区分**：这些条目 `source` 标成 `"doc:api-server-authoritative"`，
# **不是** `"spk"`。看目录的人一眼能看出"这条没经过 `.lib` 实证"。
# 只在**原本没有方法表**时填充，绝不覆盖 `.lib` 的实证结果。
DOC_METHOD_OVERLAY: dict[str, dict[str, list[str]]] = {
    # 出处：docs/api-server-authoritative.md:977-990（逐字抄，含版本分组）
    "SYNO.Personal.Notification.Conf": {
        "1": ["get", "set"], "2": ["get", "set"],
    },
    "SYNO.Personal.Notification.Device": {
        "1": ["list", "unpair"], "2": ["list"],
    },
    "SYNO.Personal.Notification.Event": {
        "1": ["delete", "get", "list", "send"], "2": ["delete", "list"],
    },
    "SYNO.Personal.Notification.Filter": {
        "1": ["list", "set"],
    },
    "SYNO.Personal.Notification.GDPR": {
        "1": ["get", "set"],
    },
    "SYNO.Personal.Notification.Identifier": {
        "1": ["get"],
    },
    "SYNO.Personal.Notification.Mobile": {
        "1": ["pair", "stat", "unpair"],
        "2": ["pair", "stat", "unpair"],
        "3": ["pair", "stat", "unpair"],
    },
    "SYNO.Personal.Notification.Settings": {
        "1": ["get", "set", "setup"], "2": ["get", "set"],
    },
    "SYNO.Personal.Notification.Token": {
        "1": ["get"],
    },
    "SYNO.Personal.Notification.VapidPublicKey": {
        "1": ["get"],
    },
}


def merge_doc_overlay(apis: dict[str, dict]) -> int:
    """把 [DOC_METHOD_OVERLAY] 补进**还没有方法表**的 API。返回补了几个。"""
    added = 0
    for api, methods in DOC_METHOD_OVERLAY.items():
        rec = apis.get(api)
        if rec is None:
            # 真机快照里也没有 ⇒ 建一条，但**不谎报版本区间**（用 overlay 的键）
            vers = sorted(int(v) for v in methods)
            rec = {
                "maxVersion": max(vers),
                "minVersion": min(vers),
                "authLevel": None,
                "allowUser": [],
                "appPriv": None,
                "normal": True,      # 文档明示「普通用户」
                "adminOnly": False,
                "methods": {},
                "methodsVerified": False,
                "source": "doc:api-server-authoritative",
            }
            apis[api] = rec
        if rec.get("methods"):
            continue  # 已有 `.lib` 实证 ⇒ **不动**
        rec["methods"] = {str(k): list(v) for k, v in methods.items()}
        rec["methodsVerified"] = True
        rec["source"] = "doc:api-server-authoritative"
        # 文档这一节明示这些是**普通用户**功能（`docs/api-server-authoritative.md`
        # 的「普通用户」列）⇒ 修正 live 快照留下的 `normal=False`/`adminOnly=False`
        # 的"未知"态。**不是**猜测：同一份文档把 `SAS.Group`/`SAS.Guest`
        # 单独标成「仅管理员（不做）」，两者是分开列的。
        rec["normal"] = True
        rec["adminOnly"] = False
        added += 1
    return added


def build(roots: list[Path]) -> dict:
    apis: dict[str, dict] = {}
    sources: list[str] = []
    for root in roots:
        files = lib_files(root)
        if not files:
            continue
        for f in files:
            try:
                data = json.loads(f.read_text(encoding="utf-8"))
            except Exception as exc:  # noqa: BLE001
                print(f"[warn] {f} 解析失败：{exc}", file=sys.stderr)
                continue
            if not isinstance(data, dict):
                continue
            sources.append(str(f))
            for api, entry in data.items():
                if not isinstance(entry, dict):
                    continue
                allow = entry.get("allowUser") or []
                if isinstance(allow, str):
                    allow = [allow]
                is_normal = any(str(a).startswith("normal.") for a in allow)
                is_admin = any(str(a).startswith("admin.") for a in allow)
                rec = {
                    "maxVersion": entry.get("maxVersion"),
                    "minVersion": entry.get("minVersion"),
                    "authLevel": entry.get("authLevel"),
                    "allowUser": allow,
                    "appPriv": entry.get("appPriv"),
                    # 同上：`.lib` 一般没有 `requestFormat`，有就带上（不臆造）。
                    **({"requestFormat": entry["requestFormat"]}
                       if entry.get("requestFormat") else {}),
                    # 口径（写进目录，免得用例各算各的）：
                    #   normal    = allowUser 里有 normal.*（普通用户可用）
                    #   adminOnly = 只有 admin.*、没有 normal.*（新规：也要 mock 验证）
                    "normal": is_normal,
                    "adminOnly": is_admin and not is_normal,
                    "methods": merge_methods(entry.get("methods")),
                    "source": "spk",
                    # SPK 的 `.lib` 就是方法表 ⇒ 方法名可校验。
                    "methodsVerified": bool(entry.get("methods")),
                }
                # 同一个 API 出现在多个包里时，取 maxVersion 大的（否则合并方法）
                prev = apis.get(api)
                if prev is None:
                    apis[api] = rec
                else:
                    if (rec["maxVersion"] or 0) > (prev["maxVersion"] or 0):
                        merged = prev["methods"]
                        for ver, names in rec["methods"].items():
                            if ver not in merged:
                                merged[ver] = names
                        rec["methods"] = merged
                        apis[api] = rec
                    else:
                        for ver, names in rec["methods"].items():
                            if ver not in prev["methods"]:
                                prev["methods"][ver] = names
    liveAdded = merge_live(apis, sources)
    print(f"[live] 实况快照补入 {liveAdded} 个 API"
          f"（这些没有方法表，方法名不校验）", file=sys.stderr)
    docAdded = merge_doc_overlay(apis)
    if docAdded:
        print(f"[doc] 文档方法表 overlay 补入 {docAdded} 个 API 的方法"
              f"（来源见各自 source 字段，**不是** .lib）", file=sys.stderr)
    return {
        "generatedFrom": sorted(set(sources)),
        "apiCount": len(apis),
        "apis": dict(sorted(apis.items())),
    }


def main(argv: list[str]) -> int:
    roots = [Path(a) for a in argv[1:]] or default_roots()

    # ── 防呆：位置参数是 **SPK 解包目录**，不是输出路径 ──────────────────
    #
    # 2026-09-23 第 31 轮我踩过这个坑：想"先生成到临时文件对比一下"，
    # 于是写了 `build_catalog.py /tmp/out_catalog.json` ——
    # 脚本把它当成**唯一的 SPK 根目录**，那目录不是目录名下的解包产物 ⇒
    # 一个 `.lib` 都没扫到，于是把 `tool/mock_dsm/catalog.json`
    # **覆盖成 1047 个「无方法表」条目**，毁掉了 1327 个带方法表的权威目录
    # （靠 `build_catalog.py`（无参）重新生成才恢复）。
    #
    # ⇒ 现在：位置参数**必须是已存在的目录**，否则**在写盘之前**就报错退出。
    bad = [r for r in roots if not r.is_dir()]
    if bad:
        print("❌ 位置参数必须是**已存在的 SPK 解包目录**，以下不是目录：",
              file=sys.stderr)
        for r in bad:
            print(f"     {r}", file=sys.stderr)
        print(
            "\n   （输出路径**不能**用位置参数指定 —— 产物固定写到 "
            f"{OUT}；\n"
            "    想只生成不落地，设环境变量 MOCK_CATALOG_OUT=<路径>。）",
            file=sys.stderr,
        )
        return 2

    cat = build(roots)
    normal = sum(1 for a in cat["apis"].values() if a["normal"])
    admin = sum(1 for a in cat["apis"].values() if a["adminOnly"])
    OUT.write_text(json.dumps(cat, ensure_ascii=False, indent=1, sort_keys=True),
                   encoding="utf-8")
    print(f"✅ {OUT}")
    print(f"   API {cat['apiCount']} 个：普通用户可用 {normal}，仅管理员 {admin}，"
          f"未知 {cat['apiCount'] - normal - admin}")
    print(f"   源文件 {len(cat['generatedFrom'])} 个")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
