#!/usr/bin/env python3
"""从 APK 的 `EmojiOne` 生成 Dart 表情表（`lib/src/data/emoji_table.dart`）。

## 为什么要有这张表

* 面板要画 1787 个内置表情（官方 `EmojiPagerFragment` 的 `emojione1..8` 八组）；
* 发/删表情回应时服务端要的是**短代码名字**（`grinning` 之类），不是 emoji 字符
  （`EmojiPresenter.setReaction` → `setPostReaction(postId, name, id)`）；
* 渲染回应/正文时再把短代码还原成字符。

## 用法（两种输入）

```bash
# ① 首选：apktool 完整反编译目录（smali + res/values/public.xml）
python3 tool/gen_emoji_table.py --apktool /tmp/chatapp \
    --categories-from lib/src/data/emoji_table.dart \
    lib/src/data/emoji_table.dart

# ② 备选：反编译出的 EmojiOne.java（带 `// drawable:` 注释的那种）
python3 tool/gen_emoji_table.py --java /tmp/EmojiOne.java lib/src/data/emoji_table.dart
```

## ★ r663 修的两个坑（都在这里守）

1. **`drawable` 名里的英文单词会被当成码点**。旧实现"从尾部取连续的 4~5 位十六进制段"，
   于是 `e_neutral_face_1f610` 里 `face` 也被当成码点 ⇒ 表里出现 `U+FACE U+1F610`
   这种"汉字 + 表情"的串（面板上就是**豆腐块**），共 20 项；同理 `1234` / `abcd`
   被当成 `U+1234` / `U+ABCD`。
   现在：**先剥掉 `e_<短代码>_` 前缀**，剩下的每一段都必须是十六进制码点；
   名字里有标点的 3 个例外（`e-mail` / `non-potable_water` / `fleur-de-lis`）
   回落到"取尾部纯十六进制段"。
2. **只取前两个码点**。旧实现为了"旗帜 / 肤色组合最多两段"硬编码 `len(out)==2`，
   于是 `family_wwb`（👩👩👦）被截成 `👩👦`、`kiss_mm` 被截成 `💋👨`。
   现在：**有几段取几段**，并把"人 + 心 + 人"这类序列按 Unicode 用 `U+200D` ZWJ
   连成组合（心形 `U+2764` 后面补 `U+FE0F`）。官方是画好的组合 PNG，
   字符渲染只有拼成 ZWJ 序列才是同一张图。
"""
import re
import sys
from collections import OrderedDict

CATEGORY_NAMES = {
    "1010": "people",
    "0x3F2": "people",
    "0x3F3": "nature",
    "0x3F4": "food",
    "0x3F5": "activity",
    "0x3F6": "travel",
    "0x3F7": "objects",
    "0x3F8": "symbols",
    "0x3F9": "flags",
}

# `arr_sticker[0x1] = new Sticker("grimacing", 1010, 0x7F08044F);  // drawable:e_grimacing_1f62c`
LINE = re.compile(
    r"new Sticker\((?:0x[0-9A-Fa-f]+|\d+)?,?\s*\"(?P<name>[^\"]+)\"\s*,"
    r"\s*(?P<cat>0x[0-9A-Fa-f]+|\d+)\s*,[^\n]*?"
    r"//\s*drawable:(?P<drawable>e_[A-Za-z0-9_]+)"
)

HEXISH = re.compile(r"^[0-9a-f]{4,6}$")

# 组合序列里允许"拼"的字符：男/女/男孩/女孩/吻 + 心
PERSON = {0x1F468, 0x1F469, 0x1F466, 0x1F467, 0x1F48B}
HEART = 0x2764

BLOCK_CTOR = "Lcom/synology/dschat/data/model/Sticker;-><init>(Ljava/lang/String;II)V"
BLOCK_CTOR_RANGE = (
    "Lcom/synology/dschat/data/model/Sticker;-><init>(ILjava/lang/String;III)V"
)


def codepoints(name: str, drawable: str):
    """从 drawable 名还原码点列表。

    drawable 名形如 `e_<短代码>_<码点>_<码点>…`：先剥前缀再逐段解析。
    名字里带标点的剥不掉前缀，回落到"取尾部连续的十六进制段" ——
    这三个名字里没有长得像十六进制的单词（这正是 `face` 那个坑的反面）。
    """
    prefix = "e_" + name + "_"
    if drawable.startswith(prefix):
        rest = drawable[len(prefix):]
    else:
        parts = drawable.split("_")[1:]
        i = len(parts)
        while i > 0 and HEXISH.match(parts[i - 1]):
            i -= 1
        rest = "_".join(parts[i:])
    tokens = [t for t in rest.split("_") if t]
    if not tokens or not all(HEXISH.match(t) for t in tokens):
        raise ValueError(f"码点解析失败：{name} / {drawable} → {tokens}")
    return [int(t, 16) for t in tokens]


def to_unicode(cps):
    """码点 → 字符；"人 + 心 + 人"这类拼成 ZWJ 组合序列。"""
    if len(cps) >= 2 and all(c in PERSON or c == HEART for c in cps):
        chunks = []
        for c in cps:
            # ❤ 默认是文字呈现，VS16 必须紧跟在它后面（不能和 ZWJ 换位）
            chunks.append(chr(c) + ("\ufe0f" if c == HEART else ""))
        return "\u200d".join(chunks)
    return "".join(chr(c) for c in cps)


def parse_java(text):
    """备选路径：直接解析 `EmojiOne.java`（带 `// drawable:` 注释）。"""
    entries = OrderedDict()
    for m in LINE.finditer(text):
        name = m.group("name")
        cat = CATEGORY_NAMES.get(m.group("cat"), m.group("cat"))
        entries.setdefault(name, (cat, to_unicode(codepoints(name, m.group("drawable")))))
    return entries


def parse_apktool(smali_path, public_xml):
    """首选路径：`new Sticker(...)` 的参数在 smali 里是**寄存器**，所以先做一遍
    线性寄存器模拟（javac 会把重复出现的常量复用同一个寄存器 ——
    比如 `microscope` 的 drawable 资源号就沿用前面某条指令写过的寄存器）。

    * 普通构造 `{obj, name, cat, res}` → `(Ljava/lang/String;II)V`
    * 肤色变体 `invoke-direct/range {obj..tone}` → `(ILjava/lang/String;III)V`，
      寄存器依次是 `obj / 0x400 / name / cat / res / tone`

    ★ 分类为什么不从 smali 取：javac 把"每个分类只写一次"的常量折叠了，
    多数条目沿用同一寄存器；模拟能拿到，但为稳妥仍由 `--categories-from`
    从上一版表按名字继承，两边交叉核对。
    """
    res_to_name = {}
    with open(public_xml, encoding="utf-8") as fh:
        for ln in fh:
            m = re.search(
                r'<public type="drawable" name="([^"]+)" id="(0x[0-9a-f]+)"', ln
            )
            if m:
                res_to_name[m.group(2)] = m.group(1)

    entries = OrderedDict()
    regs = {}
    with open(smali_path, encoding="utf-8") as fh:
        for ln in fh:
            t = ln.strip()
            m = re.match(r"const(?:/16|/4)? (v\d+), (0x[0-9a-f]+|-?\d+)$", t)
            if m:
                regs[m.group(1)] = m.group(2)
                continue
            m = re.match(r'const-string (v\d+), "(.*)"$', t)
            if m:
                regs[m.group(1)] = m.group(2)
                continue
            if BLOCK_CTOR in t:
                m = re.match(
                    r"invoke-direct \{(?P<obj>v\d+), (?P<name>v\d+), (?P<cat>v\d+), "
                    r"(?P<res>v\d+)\}, " + re.escape(BLOCK_CTOR),
                    t,
                )
                if not m:
                    continue
                name, cat, res = (
                    regs.get(m.group("name")),
                    regs.get(m.group("cat")),
                    regs.get(m.group("res")),
                )
            elif BLOCK_CTOR_RANGE in t:
                m = re.search(r"\{(v\d+) \.\. (v\d+)\}", t)
                if not m:
                    continue
                first = int(m.group(1)[1:])
                name, cat, res = (
                    regs.get("v%d" % (first + 2)),
                    regs.get("v%d" % (first + 3)),
                    regs.get("v%d" % (first + 4)),
                )
            else:
                continue
            if not name or not res:
                raise ValueError(f"寄存器取不到参数：{name!r} / {res!r} / {t}")
            drawable = res_to_name.get(res)
            if drawable is None:
                raise ValueError(f"找不到 drawable：{name} / {res}")
            base = CATEGORY_NAMES.get(cat or "", None)
            entries[name] = (base, to_unicode(codepoints(name, drawable)))
    return entries


def categories_from(path):
    """从上一版 Dart 表里读 `kEmojiCategories`（名字 → 分类）。"""
    text = open(path, encoding="utf-8").read()
    start = text.index("const Map<String, String> kEmojiCategories")
    end = text.index("const Map<String, String> kEmojiNames")
    out = OrderedDict()
    for m in re.finditer(r"^  '([^']+)': '([a-z]+)',$", text[start:end], re.M):
        out[m.group(1)] = m.group(2)
    return out


def escape(uni: str) -> str:
    return uni.replace("\\", "\\\\").replace("'", r"\'").replace("$", r"\$")


def render(entries):
    """拼出 Dart 文件内容（先拼字符串，最后一次性写 —— 别把文件截断）。"""
    lines = [
        "// 由 tool/gen_emoji_table.py 从 APK 的 `EmojiOne` 生成，**不要手改**。",
        "//",
        f"// {len(entries)} 项 emojione 短代码（`grinning` 之类）→ unicode。",
        "// 为什么需要它：",
        "//   * 发/删表情回应时服务端要的是**短代码名字**，不是 emoji 字符",
        "//     （`EmojiPresenter.setReaction` → `setPostReaction(postId, name, id)`）；",
        "//   * 渲染回应时再把短代码还原成 emoji 字符。",
        "library;",
        "",
        "/// 短代码 → unicode 表情",
        "const Map<String, String> kEmojiShortcodes = <String, String>{",
    ]
    for name, (_, uni) in entries.items():
        lines.append(f"  '{name}': '{escape(uni)}',")
    lines.append("};")
    lines.append("")
    lines.append("/// 短代码 → 分类（people/nature/food/activity/travel/objects/symbols/flags）")
    lines.append("const Map<String, String> kEmojiCategories = <String, String>{")
    for name, (cat, _) in entries.items():
        lines.append(f"  '{name}': '{cat}',")
    lines.append("};")
    lines.append("")
    lines.append("/// 反向表：emoji 字符 → 短代码（回应里拿到字符时用）")
    lines.append("const Map<String, String> kEmojiNames = <String, String>{")
    seen = set()
    for name, (_, uni) in entries.items():
        if uni in seen:  # 多个短代码指向同一字符（别名/肤色），反查保留先出现的
            continue
        seen.add(uni)
        lines.append(f"  '{escape(uni)}': '{name}',")
    lines.append("};")
    lines.append("")
    return "\n".join(lines)


def main(argv):
    args = list(argv[1:])
    cats_path = None
    if "--categories-from" in args:
        i = args.index("--categories-from")
        cats_path = args[i + 1]
        del args[i : i + 2]

    if args and args[0] == "--apktool":
        import glob
        import os

        smali_dir, out_path = args[1], args[2]
        cands = glob.glob(
            os.path.join(
                smali_dir, "smali*", "com/synology/dschat/data/model/EmojiOne.smali"
            )
        )
        if not cands:
            raise SystemExit(f"没找到 EmojiOne.smali：{smali_dir}")
        entries = parse_apktool(
            cands[0], os.path.join(smali_dir, "res/values/public.xml")
        )
    elif args and args[0] == "--java":
        out_path = args[2]
        entries = parse_java(open(args[1], encoding="utf-8").read())
    else:
        raise SystemExit(
            "用法：gen_emoji_table.py --apktool <apktool 目录> <out.dart>\n"
            "      gen_emoji_table.py --java <EmojiOne.java> <out.dart>"
        )

    if cats_path:
        cats = categories_from(cats_path)
        missing = [n for n in entries if n not in cats]
        if missing:
            raise SystemExit(f"这些短代码在旧表里没有分类：{missing[:5]}")
        entries = OrderedDict((n, (cats[n], uni)) for n, (_, uni) in entries.items())
    if any(cat is None for cat, _ in entries.values()):
        raise SystemExit("有短代码没有分类 ⇒ 传 --categories-from <旧表.dart>")

    out = render(entries)
    assert len(entries) > 1000, f"只解析出 {len(entries)} 项，拒绝写入"
    open(out_path, "w", encoding="utf-8").write(out)
    print(f"写入 {out_path}：{len(entries)} 项")


if __name__ == "__main__":
    main(sys.argv)
