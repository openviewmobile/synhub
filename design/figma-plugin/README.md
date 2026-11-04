# SynHub 设计生成器（Figma 本地插件）

> r459 · 2026-10-18。目的：**在 Figma 里先把界面设计定稿，再回代码逐屏实现**。
> 本目录是一个**本地开发插件**（不是社区插件），跑一次就在当前 Figma 文件里生成
> 「设计令牌 + 手机画板」的原生图层（文本仍是文本、矩形仍是矩形，可继续编辑）。

## 一、为什么是插件（而不是"让 AI 直接操作 Figma"）

| 方案 | 实测/文档结论 | 能不能"生成设计" |
|---|---|---|
| **Figma Dev Mode MCP**（`127.0.0.1:3845`） | 本机端口 **closed**（未启用）；且它要 **Dev/Full 席位**，方向是**读设计 → 出代码** | ❌ 不能写设计 |
| Figma REST API | 只读文件/组件 + 评论；写要 PAT 且仍不能创建图层 | ❌ |
| **本地插件（本目录）** | `figma.createFrame/createText/createNodeFromSvg` 等**就是** Figma 的写接口 | ✅ **本方案的落地** |
| Penpot（开源替代） | 浏览器端、有插件 API + REST，可自托管 | ✅ 备选，但要多一套环境 |

## 二、怎么跑（3 步，约 30 秒）

1. 在 Figma 桌面端**新建一个空文件**（或任意 Draft）。
2. 菜单 **Plugins → Development → Import plugin from manifest…** → 选本目录的 `manifest.json`。
3. 菜单 **Plugins → Development → SynHub Design Generator (r459)** 运行。

跑完当前页会出现 3 个 393×852 画板：

- `00 · 设计令牌`（颜色 / 字阶 / 硬指标）
- `01 · 现在播放`（歌词随位置滚动、全屏**只有一个 ⋮**）
- `02 · 网络电台`（行内直放 + **底部迷你播放器**：暂停 / 关闭）

> 重复运行会在同一页叠加一份（不会崩）。想干净重来：新建文件再跑。

> ⚠️ 若第 2 步 Figma 报 **manifest 无效 / 缺 id**（不同版本校验不同），走这条兜底：
> **Plugins → Development → New plugin…**（随便取个名，生成到本地）→ 把本目录 `code.js` **整份覆盖**它生成的
> `code.js` → 回到 Figma 运行该插件。效果完全一样。

## 三、改了稿怎么回到代码

1. 你在 Figma 里改（位置/文案/结构都行），并告诉我改了哪几屏；
2. 我改 `code.js` 里对应的 `draw*()` 函数 → 你重跑插件 → 画板刷新（**代码即设计源**）；
3. 定稿后按画板逐屏实现 Flutter 页面，真机做 A/B 像素对照。

## 四、不打开 Figma 也能自检

```bash
node design/figma-plugin/selftest.mjs
```

它用最小假 Figma API **真跑一遍** `code.js`，检查：3 个画板的节点数、
每个文本节点是否设过字体/字号（漏了 Figma 会报 *unloaded font*）、字体是否 `loadFontAsync` 过。
当前输出：

```
画板数 = 3（期望 3）
  · 00 · 设计令牌: 42 个节点, 393x852
  · 01 · 现在播放: 45 个节点, 393x852
  · 02 · 网络电台: 57 个节点, 393x852
文本节点 = 80，缺字体 = 0，字号异常 = 0
✅ 自检通过
```

## 五、已知边界（诚实清单）

- 画板是**绝对定位**（几何与 SVG 稿一字不差），**没有 auto-layout**；要响应式/组件化需在 Figma 里手转，
  或在 `code.js` 里改成 `layoutMode` 版本（下一版再做）。
- 图标是内联 SVG（`figma.createNodeFromSvg`），不是组件图标库；要规范图标后续导出成 component。
- 字体优先 `PingFang SC`（macOS 自带），缺失时回落 `Noto Sans SC` / `Inter` / `Arial`（`setupFonts()` 里有链）。
- 只画了 2 屏（音频流程）＋ 令牌页；其余流程按同一套 `draw*()` 继续铺。
