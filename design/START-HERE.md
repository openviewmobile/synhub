# 从这里开始看设计稿

> 代码即设计源：`design/spec/*.json`（**154 屏 = 24 个模块 + 1 张跨模块样例**）→ `emit_svg.py` / `emit_flutter.py`
> → SVG + PNG + Dart。**全部由我一个人出**，你不需要动任何设计工具。

---

## 一、三个入口（按顺序看）

| 入口 | 看什么 | 文件 |
|---|---|---|
| **① 总览** | 每屏 4 变体（暗/亮 × 中/英）缩略网格，点开看大图 | `design/gen/index.html` |
| **② 评审接触表** | 154 屏压在一张 PNG 里，一眼看全貌 | `design/gen/review.png`（PNG）／ `design/gen/review.html`（可点） |
| **③ 模块分册** | 每个模块一页（24 页），适合逐模块挑毛病 | `design/gen/module-<模块>.html` |

设计令牌：`design/tokens.py`（Dart 侧镜像 `lib/src/design/design_palette.dart`）。
组件库：`design/synhub_ui/`（组件定义）＋ `lib/src/design/generated/`（已生成的 Dart）。
一致性闸门：`python3 design/check_parity.py`（154 份 spec ↔ SVG ↔ Dart 三方对齐）。

---

## 二、★ 现在卡在你身上的三个决定

这三个不定，界面实现就只能按我给的默认值走。**每条都给了我的建议**，你回一句就行。

### 决定 1：设计稿整批是否通过？

- **A（建议）**：整批通过，允许我按稿逐屏往前实现，发现不行再单独提。
- B：先只通过某几个模块（你说哪几个），其余我继续改。

> 现状：154 屏都出了 SVG/PNG，`check_parity` 154/154 全绿，`audit` 0 违规。

### 决定 2：Material You（动态取色）留不留？

- **A（建议）**：**保留但默认关**。壁纸取色常常把品牌蓝染成紫/绿，主界面观感会飘；
  开关留在「设置 → 外观」，想用的人自己开。
- B：保留并**默认开**（现在就是这个状态）。
- C：整个删掉，只用品牌蓝。

> 现状：开关默认开，但我实测界面仍渲染品牌蓝 —— 也就是**取色到底生效没有，我没验证成**。

### 决定 3：亮色主题的验收范围

- **A（建议）**：亮色按"能看、能读"验收（对比度达 AA、层级正常），
  但**不要求**和暗色一样逐屏打磨细节。
- B：要求亮色和暗色同等精细，那就还要再花一轮逐屏扫。

> 现状：暗色已逐屏扫到 `DA174`；亮色的深页（相册收藏/人物、文件附件/PDF 预览、
> Drive/聊天深页、阅读器）还没扫完。

---

## 三、怎么改

```bash
# 改某一屏：编辑 design/spec/<id>.json → 重出
python3 design/emit_svg.py && python3 design/emit_flutter.py
python3 design/check_parity.py && python3 design/audit.py
python3 design/make_index.py        # 刷新总览
python3 design/review_sheet.py      # 刷新评审接触表
```

改令牌只需要动 `design/tokens.py`（两套主题各一份），再重出。

---

## 四、已知的诚实缺口（没藏）

* 阅读器 AI 助手面板 / 书签 / 目录菜单、`.oslides` 备注与放映面板 —— **未验**；
* 亮色深页若干（见决定 3）；
* Material You 是否真的取到壁纸色 —— **未验证**；
* 底部弹层的"玻璃"半透明会让下层文字隐约透出（`r540_03`）—— 这是**有意的设计**，
  你觉得碍眼的话我改成实底。
