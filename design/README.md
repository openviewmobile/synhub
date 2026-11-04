# SynHub 设计系统 / 设计工具链（r459）

> 一句话：**设计由我用这条链完成**，不依赖任何人在 GUI 里点。
> 一份 `spec` → 同时产出**设计稿（SVG/PNG）**和**界面代码（Flutter）** ⇒ 设计与代码永不漂移。

## 1. 目录

```
design/
  synhub_ui/generate.py     全量画板生成器（令牌 + 组件库 + 160 个界面单元的骨架稿）
  spec/*.json               ★ 界面规格（唯一真源）：一屏一份
  emit_svg.py               spec → design/gen/svg/<id>.svg + .png
  emit_flutter.py           spec → design/gen/flutter/<id>_page.dart（可直接编译）
  check_parity.py           ★ 一致性闸门：spec 文案必须同时出现在 SVG 与 Dart
  figma-plugin/             （备选）把设计稿 native 生成到 Figma 的本地插件
  figma/                    （备选）SVG 母版，可导入 Figma / Penpot
  gen/                      产物（svg / png / flutter 代码）
```

## 2. 一条命令的两半

```bash
# 设计稿：默认暗色·中文；再出英文与亮色变体（命名 ai_*.light.en.svg）
python3 design/emit_svg.py design/spec/audio_library.json
python3 design/emit_svg.py design/spec/audio_library.json --theme light --locale en

# 界面代码：一份文件同时含 zh/en 文案 + 双主题取色
python3 design/emit_flutter.py design/spec/audio_library.json

python3 design/check_parity.py      # 闸门：zh/en × SVG/Dart 四边一致
flutter analyze design/gen          # 生成的代码必须无告警
```

## 3. spec 里有什么

```jsonc
{
  "id": "audio_library",                  // 唯一 id（决定文件名与类名 AudioLibraryPage）
  "unit": "lib/src/features/audio/audio_page.dart",  // 对应矩阵台账的界面单元
  "title": { "zh": "音乐库", "en": "Music" },          // ★ 文案两种语言都给
  "appbar": { "actions": ["search", "more"] },
  "tabs": [{ "zh": "歌曲", "en": "Songs" }, { "zh": "专辑", "en": "Albums" }],
  "body": { "type": "list", "items": [
    { "title": "Demo Song", "sub": { "zh": "Demo Artist · 3:51 · 320 kbps",
                                   "en": "Demo Artist · 3:51 · 320 kbps" } }
  ] },
  "bottomNav": null,
  "fab": false,
  "search": { "hint": { "zh": "搜索歌曲、专辑、艺术家",
                        "en": "Search songs, albums, artists" } }
}
```

已支持的 `body.type`：`list` / `grid` / `empty`（下一步：`player` / `settings` / `form` / `detail` / `chart` / `map` / `viewer`）。

★ 文案字段（`title` / `tabs[]` / `items[].title|sub` / `search.hint`）既可以是纯字符串（两种语言同文），
也可以是 `{"zh":…,"en":…}`。**新 spec 一律要求双语**，否则闸门只验一边。

## 4. 闸门（当前实跑结果）

```
$ python3 design/check_parity.py
[ok] audio_library: 14 组文案 ×2 语言 / SVG+Dart 双侧一致
[ok] photos_grid: 5 组文案 ×2 语言 / SVG+Dart 双侧一致
✅ 一致性闸门通过（2 份 spec）

$ python3 design/audit.py
== 全局令牌检查 ==
  dark  dim   on surface =  4.63:1  OK
  light dim   on surface =  5.50:1  OK
  ...
共 0 条 / 0 屏

$ flutter analyze design/gen
No issues found! (ran in 1.9s)

$ python3 design/make_index.py
[ok] design/gen/index.html  (153 屏)

$ python3 design/emit_gallery.py
[ok] 画廊 153 屏 → lib/src/design/design_gallery.dart
```

四条闸门 + 一条画廊生成，缺一不可：

| 工具 | 管什么 | 什么时候会红 |
|---|---|---|
| `check_parity.py` | spec 文案是否**同时**出现在 SVG 与 Dart | 少画一句、Dart 漏一个 key |
| `audit.py` | 设计规则（见 §4.2） | 列表超 8 行、表单超 5 字段、对比度不足、整行重复、日历标记越界 |
| `flutter analyze design/gen` | 生成的 Dart 能不能编译 | 未定义 getter / 未用参数 |
| `make_index.py` | 153 屏 × 4 变体的总览页 | 产物缺失 |
| `emit_gallery.py` | 把 153 屏装进 App 的**真机画廊** | 生成的 Page 类名对不上 spec |

## 4.2 `audit.py` 的十条规则

| 规则 | 判据 | 为什么会有这条 |
|---|---|---|
| R1 | 列表 ≤ 8 行 | 渲染器上限 8 行，多的会被**静默吞掉**（真踩过：设置主页 7 行时"关于"消失） |
| R2 | 表单/字段值一行放得下 | 表单没有省略号兜底，超了直接压边框 |
| R3 | 工具栏 ≤ 5 个动作 | 一行排不下会挤成两截 |
| R4 | 表单 ≤ 5 个字段 | 键盘弹起后放不下提交按钮 |
| R5 | 网格 ≤ 9 格 | 首屏之外用户不知道还有更多 |
| R6 | 日历标记落在 1..days | 越界标记画不出来 |
| R7 | `muted`/`dim` 在 `surface`/`bg` 上 ≥ 4.5:1 | WCAG AA；**本轮实测 `dim` 两套主题都不达标**（暗 3.85 / 亮 2.97） |
| R8 | 同一屏没有 title+sub 完全相同的两行 | 复制粘贴没改，用户看到两条一模一样的 |
| R9 | 文档/文本视图必须有正文 | 否则画出来是占位灰块（真踩过：Office 文档页正文空白） |
| R10 | 列表行高 ≥ 48 | 点击区下限 |

## 4.3 真机画廊（评审载体）

设计稿不再只躺在 PNG 里：

```
设置 →（dev 档）设计稿画廊 → 153 屏缩略图 → 单屏 1:1 + 中/英 + 暗/亮 一键切
```

构建（**评审用**，发布产物不许带）：

```bash
SYNHUB_SIGN=release SYNHUB_EXTRA_DEFINES="--dart-define=SYNHUB_DEV_TOOLS=true" \
  ./scripts/build_arm64_release.sh
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

页面本体在 `lib/src/design/generated/`（由 `emit_gallery.py` 从 `design/gen/flutter` 拷入），
画廊外壳在 `lib/src/design/design_gallery.dart`。**设计改一行 → 重跑 `emit_gallery.py` → 真机就是新稿。**

三条实现细节（都是踩过才加的）：

1. **生成类名带 `Design` 前缀**（`DesignSettingsPage` / `DesignDiagPage`）——
   否则和工程里真实页面同名：`dev_tools_gate_test` 按类名找"临时页面引用"，
   `Design` 前缀前的 `DiagPage` 子串会让它误判成"未加固的调试入口"。
2. **缩略图用 `FittedBox` 等比缩放**，不是 `OverflowBox` ——
   后者只是裁剪，真机上看到的是"放大 2 倍的左上角"，会把字号评审全带偏。
3. **单屏查看钉死 `textScaler: noScaling`** ——
   设备字体放大是用户偏好，但评审要按 1.0 字号判"放不放得下"。

**三条静态守卫的例外都已写明理由**（不是"看着像"绕过）：
`i18n_hardcoded_cjk_test` / `i18n_source_scan_test` / `dart_dev_note_guard_test`
跳过 `lib/src/design/`（中英文成对写在 `_zh ? … : …` 里，文案即设计源；
只经 dev 档可达，release 不被引用）；`dev_tools_gate_test` 的**引用面**跳过
`lib/src/design/`（改由**路由面**兜底：`/design/gallery` 必须挂在 `if (kDevTools)` 内）。

## 4.1 主题与语言（用户 2026-10-18 明确要求）

| 维度 | 设计侧 | 代码侧 |
|---|---|---|
| 主题 | `design/tokens.py` 里 **dark / light 两套令牌**，同一 spec 渲染成两种稿（`--theme light`） | `DesignPalette.of(context)` 按 `Theme.of(context).brightness` 取色；`DesignTheme.light/dark` 两套 ThemeData |
| 语言 | 同一 spec 的文案是 `{zh, en}`，渲染 `--locale en` 出英文稿 | 页面内 `_Strings` 同源生成 zh/en；`DesignPalette.localeOf(context)` 取系统语言 |
| 一致性 | 闸门同时比 **zh/en × SVG/Dart 四边**（缺一边就红） | 页面禁止裸色值（`Color(0x…)` 只许出现在 `design_palette.dart`） |

★ 两条设计纪律（因语言/主题而加）：
1. **英文文案比中文长 1.3–1.8 倍** —— 关键动作（播放/下载/重试）不许靠 `TextOverflow.ellipsis` 兜底，
   该涨的宽度在设计稿里就要涨出来；
2. **亮色不是"暗色反色"** —— 卡片/背景/分割线在亮色下靠 `line` 边框建立层次（已实测：不加边框白色卡片会"糊"在白色页面上）。

## 4.4 落到 `lib/` 的组件层（r469 起）

设计稿 → 真代码不是"再画一遍"，而是先落一层**几何与令牌都来自 spec** 的积木：

```
lib/src/design/kit/design_kit.dart
  DesignScaffold     底色 phone / 顶栏 15-600 实色（HUD 的半透明顶栏会漏底纹）
  DesignSectionHeader 13-600 text 色
  DesignRowTile      62 起 / 图标块 40-圆角11-primarySoft / 标题 13-600 / 副标题 11.5 muted
  DesignSwitchRow    旋钮固定白（onPrimary 在暗色是深藏蓝，落在亮蓝轨道上像个洞）
  DesignNote         surface + line 边框 + info 图标 + 11.5 muted
  DesignPrimaryButton 高 48 / 圆角 26
```

**r470 又统一了一处设计分裂**：`settings` 类型（23 份 spec）原来画"平铺行 + 分隔线"，
而设置主页（`list` 类型）画"一行一张卡片" —— 同一族两套皮。现在
`render_settings`（SVG）与 `settings_classes`（Dart）都改成卡片行，612 张稿全部重出。

**已按设计稿改造并真机核对的页面**（9 屏，设置模块收口）：

| 页面 | 文件 | 真机证据 |
|---|---|---|
| 设置主页 | `lib/src/features/settings/settings_page.dart` | `design/gen/device-settings-light-r469.png` / `-dark-` |
| 端到端加密 | `lib/src/features/settings/e2ee_page.dart` | `design/gen/device-e2ee-r469.png` |
| 机器人 | `lib/src/features/settings/bots_page.dart` | — |
| 免打扰 | `lib/src/features/settings/snooze_settings_page.dart` | — |
| 个人资料 | `lib/src/features/settings/personal_profile_page.dart` | — |
| 通知与后台 | `lib/src/features/settings/notification_settings_page.dart` | `design/gen/device-notifications-r470.png` |
| 服务检测 | `lib/src/features/settings/service_check_page.dart` | `design/gen/device-service-check-r470.png` |
| 厂商保活 | `lib/src/features/settings/oem_keepalive_page.dart` | `design/gen/device-oem-keepalive-r470.png` |
| 资料编辑 | `lib/src/features/settings/profile_edit_page.dart` | — |

改造方式是**只换视觉层**：`HudScaffold→DesignScaffold`、`ListTile→DesignRowTile`、
`SwitchListTile→DesignSwitchRow`（后两者的具名参数与 Material 同名同义），
业务回调、权限门控、i18n 一律不动。

设置模块 **9/9 已收口**。这一轮撞到的三条（都记进代码注释）：

1. **分组名不能和行同名**：BOOT 组原来也叫「开机自启」，改完卡片后两行文本一模一样
   ⇒ 新增 `notifBootSection`（启动 / Startup）；
2. **HUD 遥测条不能直接删**：它承载真读到的状态（SVC/CONN/SOCKET/NATIVE/DND），
   设计稿没有这一条 ⇒ 收成一张 `DesignNote`，信息不丢、语言统一；
3. **Material `Card` 老页面**：卡片底色 = 页面底色，真机看不出是卡片
   ⇒ `DesignScaffold` 补 `cardTheme`（surface + line + 13）。

## 4.5 r471：audio 模块开工 —— 两条真机缺陷

按 spec `audio_radio`（无播放条）与 `audio_song` 的歌词区，真机上先修了两条**用户点过的问题**：

| 缺陷 | 真机现象（证据） | 修法 |
|---|---|---|
| **电台页没有播放器** | 起播后这一页什么都不显示，想暂停/关掉只能退出页面 | 页内加「正在播放」条：只读 `audioHandler` 的 `playbackState` + `mediaItem`（单一状态源，不自己维护 bool）；`processingState == idle` 也当作没在播（`stop()` 后 `mediaItem` 不一定被清空，只看它会留下"在播"的假信息 —— 用例②就是抓这个）。证据 `design/gen/device-radio-now-playing-r471.png` |
| **歌词区按钮横向溢出** | 有候选版本时两个按钮并列，`Search lyrics o…` 被屏幕右缘切掉（点不到也读不全） | `Row(Spacer+…)` → `Align + Wrap`：放得下靠右一行，放不下换行。证据 `design/gen/device-lyrics-row-r471.png` |

新用例 `test/audio_radio_now_playing_test.dart`（3 条：没在播不出现 / 起播出现且暂停·关闭真生效 / 反向"别处点的歌也显示"）。

**诚实缺口**：`Demo Song` 这类曲目，公开源（lrclib）只给**纯文本歌词**（无时间轴）⇒ 界面按契约平铺 + 标注"无时间轴"，不会假装跟随；这不是渲染缺陷，是**源**的限制。带时间轴的路径由 `test/audio_lyrics_view_test.dart` 覆盖（同一 `position` 不同行高亮）。

## 4.6 r472：audio 第一屏落地 —— 歌词自动匹配 ＋ 电台页设计语言

| 变更 | 判据 |
|---|---|
| **歌词自动匹配**（用户 r468「歌词不随进度」的根因修法） | 打开单曲页：先读缓存，再**静默**补一次公开源；**只有拿到带时间轴的那份才替换**（纯文本不换，免得内容乱跳）；`idle`/失败一律不打扰；用户选过的版本不回退（DA69 的老规矩） |
| 真机复验 | `Shape of My Heart`：**没点任何按钮**，署名行就是 `lrclib.net public lyrics`，两帧（间隔 12 s）高亮行**不同** ⇒ 歌词真的跟着 `positionStream` 走。证据 `docs/evidence-r472/` |
| 电台页换成设计语言 | `HudScaffold → DesignScaffold`；分类/电台行 `ListTile → DesignRowTile`（卡片）；说明文字 `TelemetryLabel → DesignNote`（`DA108`：原来被截成 `…tap a station to start…`，正好丢"只列表、不播放"） |

新用例：`test/audio_g2_test.dart` 的 `r472` 组（自动匹配触发 ＋ 反向「已有时间轴就不联网」）、`test/audio_radio_note_da108_test.dart`。
订正一处老用例：`test/audio_page_test.dart` 的 DA67 组原来断言"搜之前不许有『换一个歌词版本』"——自动匹配上线后候选会先到位，改成断言"有候选才出现"，语义没松。

下一屏：单曲页本体（现在仍是 HUD 切角面板 + 大圆盘，与设置/电台两处的设计语言不一致）。

## 4.7 r473：单曲页第一刀（壳与层级）

| 变更 | 判据 |
|---|---|
| `HudScaffold → DesignScaffold`；播放面板 `hud.glass` 切角 → 设计卡片（`surface` + `line` + 13） | 真机同帧：卡片底色/边框与设置页一致 |
| 歌词段标题 `TelemetryLabel → DesignSectionHeader` | 与设置/电台同一套组标题 |
| **技术信息让位**（`DA109`）：`Streaming URL` / 脱敏说明整块从卡片**最上面**移到末尾 | 用例钉顺序：`as-play` 的 `dy` < `as-stream-url` 的 `dy`；真机两帧 `docs/evidence-r473/` |

★ **这一刀只统一了壳与层级，还没长成 spec 的样子**：`design/spec/audio_song.json` 画的是
"封面 + 歌名/歌手 + 进度 + **内联歌词（高亮行）** + 快捷动作（队列/投送/音效/睡眠）"，
而现在页面里仍是"大圆盘视觉 + 音质 chip + HUD 等宽标签"。下一轮按 spec 重排主体，
键名与行为（`as-play` / `as-quality-*` / `as-stream-url` …）全部保留，127 条音频用例是护栏。

## 4.8 r474：单曲页第二刀（音质可见性 ＋ 装饰块让位）

| 变更 | 判据 |
|---|---|
| `DA110`：三档音质最后一档被右缘切掉 | 标签 `Quality` 提到上面一行、chip 行拿满宽度；用例钉 `as-quality-320000` 的 `right ≤ 屏宽`；真机两帧 `docs/evidence-r474/` |
| 播放视觉块 140 → 96 + `compact` | 真机同帧：装饰块不再占约 1/4 屏，播放键与音质行整体上移 |

★ **未成的一条，如实记**：给视觉块喂了内嵌封面（`coverBytes`，它只用来取主色），
真机上圆环仍是身份色（紫），没有变成本曲封面的橙红 ⇒ **这条没验成、也还没查明**
（可能是 `mediaCoverProvider` 首帧为空、也可能这条命令取不到内嵌封面）。
下一轮先查这条再谈"封面块"，不许把它写成"已支持封面配色"。

## 4.9 r475：单曲页第三刀（封面块 ＋ 面板字体）

| 变更 | 判据 |
|---|---|
| `DA111`：播放区的**空渐变圆**换成真封面块 `_SongCoverBlock`（120dp，与页头**同一条**链路：内嵌封面 → `getsongcover` → 图标占位） | 用例：`as-song-cover-block` 有 **且** `as-visualizer` 无；真机两帧 `docs/evidence-r475/` |
| 圆环/律动柱从单曲页移除 | 能力没删：文件预览播放器 `media_audio_stage.dart` 仍在用 |
| `Quality` / `Sleep timer` / `Streaming URL` 三个小标题 `TelemetryLabel → _PanelLabel`（设计字重/字距） | 真机同帧：三处字重一致、不再等宽 |

★ 上一轮"给视觉块喂封面取主色"的未验项，**本轮直接取消**（圆环已删）——
不留"半生效"的接线，也不把它写成"已支持封面配色"。

## 4.10 r476：单曲页第四刀（字体收口 ＋ 详情卡）＋ **一条试修回退**

| 变更 | 判据 |
|---|---|
| `_MetaLine`：页头元信息 / `Rating` / `Unrated` / `在线标签` 组标题 → 设计字体（不再等宽） | 真机两帧 `docs/evidence-r476/`（修前 vs 修后） |
| 详情表 15 行小字 → **设计卡片**（`surface` + `line` + 13，label `muted`） | 同目录 `r476_03_*`（卡片与页面上其它卡片同一几何） |
| 清掉一处**悬空 doc 注释**（`_SongVisualizer` 删了、它的文档注释被 Dart 归到了 `redactStreamUrl` 头上） | 读码可见：`redactStreamUrl` 的注释只剩打码那段 |

### 试修→回退（未编号，记账在此）

`SyncedLyricsView` 的 `padding: vertical: height/2` 在**没有活动行**时（没起播/还没到第一句）
也照样留 ⇒ 真机歌词卡顶部空半屏。试过"有活动行才留半屏"，**当场量到高亮行被挤到视口底部**
（`docs/evidence-r476/device/r476_04/05_*`）。

根因不是 padding，是 `lyricCenteredScrollOffset()` 的公式
（`raw = index*lineHeight - (viewport - lineHeight)/2`）**没把 top padding 算进去**——
改了 padding，公式与真实坐标就差了半个视口。

⇒ 本轮**回退**，不把"改 padding"当修好。下一轮修公式（让 `topPadding` 进参数），
并补一条"起播后高亮行仍在视口中部"的用例（现在只有"高亮存在"的用例，钉不住位置）。

## 4.11 r477：歌词居中修好（`DA112`）

| 项 | 修前 | 修后 |
|---|---|---|
| `lyricCenteredScrollOffset()` | 公式 = `index*行高 − (视口−行高)/2`，**等价于"顶部留白 = 0"** | 增加 `topPadding` 参数，公式与真实坐标同一套 |
| 列表留白 | 恒定半屏（没高亮行时也留 ⇒ 顶部白半屏） | `_pad`：有高亮行留半屏、没有只留 8dp；**同一个值**同时喂 padding 与公式 |
| 真机 | 高亮行贴视口底部、被 `Search lyrics online` 切掉 | 高亮行停在视口中部（`docs/evidence-r477/`） |

用例 4 条（`test/audio_lyrics_view_test.dart`，名里含 `DA112`）：
公式吃 topPadding · 留白 0 时与老公式等价 · **起播后高亮行停在视口中部 ±40dp** · 无高亮行不留半屏。

★ r476 的"只改留白不改公式"已回退并留证 —— 这条缺陷是**两次尝试**才闭：第一次翻车被真机像素抓到，
第二次把公式一起改才成立。教训写在这里：**改布局参数前先问"算坐标的那一方知道这个参数吗"**。

## 4.12 r478：单曲页第五刀（快捷动作行，`DA113`）

| 项 | 前 | 后 |
|---|---|---|
| 常用动作 | 队列在顶栏图标；投送/音效要**退回首屏**再从「更多列表」菜单找 | 播放键下方一条 `_QuickActions`：播放队列 / 投送 / 音效（48dp 高、`surface2` + `line`、圆角 11） |
| 睡眠定时 | — | **不重复给入口**（已有自己一行；重复入口正是用户抱怨的"菜单冗余"） |
| 双语 | `asCast`/`asEffects` 未登记 ⇒ 英文界面里"投送/音效"回落中文 | `asQuickCast`/`asQuickEffects` 四件套齐全（zh/en ARB + gen 产物 + dataTextMap） |

★ 这条是**真机第一次上机就抓到**的：一条行里三块语言不一致（`docs/evidence-r478/`）。
回归：`test/audio_page_test.dart`（含 `DA113`）＋ `test/i18n_coverage_test.dart`。

## 4.13 r479：均衡器页（`DA114`）

| 项 | 前 | 后 |
|---|---|---|
| 组件 | 整页 `SwitchListTile` + `ListTile`（裸 Material 默认样式） | `DesignSectionHeader`（组标题）+ `DesignSwitchRow` + `DesignNote`（说明卡）+ `DesignRowTile`（预设行） |
| 键位 | `as-eq-enable` / `-gapless-hint` / `-unsupported` / `-no-presets` / `-preset-*` | **一个没动**（既有用例与真机走查都靠它们） |
| 双语 | 组标题 `总开关` 只有中文回落（真机首帧就是它） | `asEqGroupMaster` / `asEqGroupPresets` 四件套齐全 |

### spec 偏差（不造假 UI）

`design/spec/audio_equalizer.json` 的 **Bands 5 条滑块**这条**平台给不了**：本机原生通道只暴露开关，
没有逐频段读写。这里**不画一排拖了没效果的滑块**，而是在本节记偏差。

### 教训（第二次同类）

"新增 key 只有中文回落"这轮又发生了一次（r478 是 `asCast`/`asEffects`，r479 是 `asEqGroupMaster`）。
`test/i18n_coverage_test.dart` 两次都当场抓住 —— 这个守卫有用，但**我写新 key 时还是忘了先登记**。
规矩收紧：**凡 `dataText('新key', …)`，同一个补丁里必须同时改 ARB×2 + dataTextMap + 跑 gen-l10n**。

## 4.14 r480：投送页（`DA115`）＋ **坐标 ×1.25 的仪器订正**

| 项 | 前 | 后 |
|---|---|---|
| 组件 | `AppEmptyState` + 裸 `ListTile` + 裸 `FilledButton` | `DesignSectionHeader` + `DesignRowTile` + `DesignNote` |
| spec 偏差 | spec 写了两句（不支持 + **可以改用 DLNA**），屏上只有第一句 | 两句都在：空态 + 说明卡里的替代路 |
| 双语 | 新 key `asCastDlnaHint` / `asCastGroupDevices` | 四件套齐全（r478/r479 的教训照办，本轮**没有**再犯） |

### ★★★ 仪器订正（r479 的错判）

r479 我写过「单曲页那片按钮点不动，hit-test 与截图不一致」。**错**。
真相：这台机器 **`input` 坐标 = 画面坐标 × 1.25**。五处交叉验算：
底栏「Me」1878→2345 · 菜单 669→809 · 播放键 1127→1409（**音乐真开始播**）·
Effects 1244→1555（**真进均衡器**）· Cast 1244→1555（**真进投送页**）。

副产品：**`DA113` 的快捷行动作本轮补上了真机证据**（r478 只证明"行画出来了"）。

规格教训：**说"点不动"之前，先用一个已知控件反算比例** —— 错判会让人去改没坏的代码。

## 4.15 r481：收藏页 + 「发现」家族（`DA116` / `DA117`）

| 屏 | 前 | 后 |
|---|---|---|
| 收藏（`audio_pins_page.dart`） | `HudScaffold` + 裸 `ListTile`，顶栏**零动作**（spec 写的是 search + more） | `DesignScaffold` + `DesignRowTile`，顶栏 **搜索 / 刷新两个图标** |
| 最近添加 / 随机 100 / 最近播放（`audio_gaps_page.dart`） | 3 个 `HudScaffold` + 裸 `ListTile` + `Divider(height:1)` | `DesignScaffold` + `DesignRowTile`，行间距 2（设计稿没有分隔线） |

### ★ spec 偏差（写在这里，不当没发生）

`audio_pins.json` 的 `appbar.actions` 写的是 `["search","more"]`，实稿是**两个图标**、没有 ⋮。
理由：这一页一共就两个动作，用户抱怨的原话是「常用动作被藏进菜单」——
把唯一两个动作塞进 ⋮ 正好是那条抱怨。⇒ **偏差保留**，spec 的语义（两个动作可达）
由 `test/audio_pins_gaps_design_test.dart` 的 ③ 号判据守住（并且**反向断言"不许有 PopupMenuButton"**）。

### 复用键，不造新键

"搜索音乐 / 刷新"复用已有 `asSearchTitle` / `photoRefresh` —— r478/r479 两次栽在
"新增 dataText 键必须四处齐全"，这轮**干脆不新增键**（能复用就复用）。

## 4.16 r482：音乐库主页（`DA119`）＋ 列表体积截断（`DA120`）

| 项 | 前 | 后 |
|---|---|---|
| 骨架 | `HudScaffold`（网格底纹透在内容后面） | `DesignScaffold` |
| 行 | 5 处裸 `ListTile` + `Divider` | `DesignRowTile`（圆角卡 + chevron） |
| 分页条 | Material 默认（亮青指示条 + 玻璃底） | `_DesignTabBar`：`p.primary` 指示条 / `p.text`·`p.muted` 字色 / 13-600 |
| 顶栏 | **6 个图标**（搜索·电台·队列·收藏·音乐库·⋮） | **3 个**（搜索 / 音乐库 / ⋮）；电台·队列·收藏进「更多」 |
| 次要行 | `3:51 · 320 kbps · 44.1 kHz · 9.0 MB` ⇒ 真机切成 `9.0…` | `3:51 · 320 kbps · 44.1 kHz`（体积留详情页） |

### 顶栏"该放什么"的判据（回答"菜单太多 / 又藏太深"这对矛盾）

**顶栏只放"每一屏都要用"的动作**；其余进**一个**明确的「更多」。音乐库首页每屏都要用的只有
「搜索」和「切换音乐库」⇒ 电台/队列/收藏是"偶尔去一次"，与「最近添加/随机100/…」同处。
用例反向断言 **顶栏 `IconButton` ≤ 3**，防止下一轮又加回去。

### 已知未做（下一轮）

「更多」菜单现在 **11 项**，本身开始"太挤"。设计答案是换成**带三组标题的底部弹层**
（媒体源 / 快捷列表 / 播放与投送），而不是继续往 `PopupMenu` 里堆。

## 4.17 r483：「更多」＝分组弹层（`DA121`）

| 前（r482） | 后（r483） |
|---|---|
| `PopupMenuButton`，**11 项平铺**（电台/队列/收藏 ── 分隔线 ── 8 项） | `showModalBottomSheet` + 三组 `DesignSectionHeader` |
| 行高 48、窄条、只有文字 | 行高 56、整屏宽、**每行带图标 + chevron** |
| 分组只有一条分隔线（无标题） | **媒体源 / 更多列表 / 播放与投送** 三个标题 |

### 键名策略（省掉 12 处用例重写）

弹层行**沿用同一批键**（`as-radio` / `as-webqueue` / `as-pins` / `as-home-*`）——
既有用例只需"先点开入口"这一步不变，**判据一条没改**。
⇒ 规矩：**改呈现形式时，先想办法保住键**；键就是行为契约。

### 新键（4 处齐全）

`asMoreSources`（媒体源 / Media sources）、`asMorePlayback`（播放与投送 / Playback & casting）
—— zh/en ARB + `flutter gen-l10n` + `dataTextMap` 一次补齐（§2.0.13/§2.0.67）。
分组二复用既有 `asMoreLists`（"更多列表"），**没有为分组标题造第三个别名**。

## 4.18 r484：字号也是令牌（`DA123`）＋ 生成器物产必须原子写

### 4.18.1 `TYPE` 表（`design/tokens.py` 是唯一真源）

10 个 Material 角色，逐条 `(size, weight, height, letterSpacing, 颜色角色)`：

| 角色 | size / weight | 用途 |
|---|---|---|
| `headlineSmall` | 20 / 600 | 大数字、播放器标题 |
| `titleLarge` | 17 / 600 | 详情页主标题 |
| `titleMedium` | 15 / 600 | **顶栏标题 / 分页条选中** |
| `titleSmall` | 13 / 600 | **行标题** |
| `bodyLarge` | 14 / 400 | 段落 |
| `bodyMedium` | 12.5 / 400 | 正文默认 |
| `bodySmall` | 11.5 / 400 | **行副标题** |
| `labelLarge` | 13 / 600 | 主按钮 |
| `labelMedium` | 12 / 500 | 芯片 |
| `labelSmall` | 11 / 500 | meta / telemetry |

`emit_flutter.py` 把它生成 `DesignType`（`*Size` 常量 + `textTheme()`），
`DesignTheme` 直接用它当 `textTheme`，`DesignRowTile` 等组件也只用常量。
**页面不许再写裸 `fontSize:`**；改字号只改 `design/tokens.py` 一处。

### 4.18.2 ★ 生成器必须原子写（本轮真踩了）

```python
# ✗ 错：open 先截断，再算内容 ⇒ 算的时候抛异常，产物已经 0 字节
open(path, 'w').write(build())

# ✓ 对：先算完、断言长度、写 .tmp、再原子替换
_write_atomic(path, build())
```

后果不是"少一个文件"：`design_palette.dart` 两个副本同时归零 ⇒ `flutter analyze lib`
报 1101 个错误，看起来像"整个设计系统塌了"。守卫：`_write_atomic` 里
`assert len(text) > 500`。

## 4.19 r485：专辑详情页（`DA124`）

| 项 | 前 | 后 |
|---|---|---|
| 骨架 | `HudScaffold` | `DesignScaffold` |
| 行 | 3 处裸 `ListTile`（专辑 / 名字型 / 文件夹） | `DesignRowTile` |
| 元信息 | `TelemetryLabel(size: 11, color: HUD.meta)` | `DesignType.labelSmallSize` + `p.dim` |
| 顶栏 | 只有「收藏」 | **搜索 + 收藏**（设计稿 `[search, more]`；本页的 more 就是收藏） |

★ 判据："设计稿写了 `[search, more]`"不等于"必须造一个只放一项的 ⋮" ——
**有副作用的那个动作本身就是 more**。写实稿时按"它要解决什么"对齐，而不是按字符串对齐。

## 4.20 r486：音频子页收口 ＋「看不见/看不懂」两条真机规则

* **`DA126`**：列表行**空名字必须有占位**（`asDisplayName`）。服务端会给 `name: ""`，
  而 `Text('')` 就是一行看不见的可点区域 —— 这正是用户第 4 条抱怨的形态。
* **`DA127`**：**认不出的标题不许原样画**（`asQueueDisplayTitle`）：先判"像不像人话"，
  不像就退回文件名，文件名也不行才用"未命名"。判据写在函数注释里
  （Latin-1 补充区 + 希腊区占比 > 0.3）。
* 组件侧：`AudioSongTile` 增加 `titleOverride`，元信息行从 `TelemetryLabel(size: 11)`
  改成 `DesignType.labelSmallSize`（字号只从令牌来）。

## 4.21 r487：单曲页收口 ＋ 音频模块「零硬编码字号」

* 5 处裸 `ListTile` → `DesignRowTile`；11 处 `HudTokens` 清零（`meta`→`p.dim`、`warning`→`p.danger`）。
* **`size: 11` 在 `lib/src/features/audio/` 归零** —— 元信息一律 `DesignType.labelSmallSize`。
  守卫写成源码反向（`expect(src.contains('size: 11'), isFalse)`），以后谁再写死就红。
* 遗留：`TelemetryLabel` 自身默认 11.5（组件契约），4 处调用不传 size；页面侧不再写死。

## 4.22 r488：下载模块整批迁移 ＋ 一条机械替换的真坑

### 4.22.1 批量迁移 12 个页面（`DA129`）

`HudScaffold`→`DesignScaffold`、裸 `ListTile`→`DesignRowTile`、HUD 令牌→调色板、
`field_backdrop` 清零。**一次扫全模块**的守卫写在 `test/downloads_design_test.dart`：
清单 = 目录里带 `DesignScaffold(` 的那些文件（**不是手抄的名单**）。

### 4.22.2 ★ 字符串替换会误伤带前缀的组件名

```python
s.replace('ListTile(', 'DesignRowTile(')      # ✗ 同时把下面两个也改了
SwitchListTile(  → SwitchDesignRowTile(      # 不存在
CheckboxListTile(→ CheckboxDesignRowTile(    # 不存在
```

规矩：**改组件名用整词/前缀感知的替换**（正则 `(?<![A-Za-z])ListTile\(`，
或先替换长名字再替换短的）；改完**立刻** `flutter analyze` —— 一个文件里
8 处这种误伤，analyze 会一次全部报出来，别靠肉眼。

### 4.22.3 新增 `DesignCheckRow`

`CheckboxListTile` 的设计版：`DesignRowTile` 外框 + `p.primary` 填充的白勾。
下载模块 4 个勾选点从此不再用 Material 组件。

## 4.23 r489：骨架层归零 ＋ 三档覆盖率守卫

### 4.23.1 「硬零 / 棘轮 / 下界」三档

`HudScaffold(` 归零后，剩下的旧形态是**行/令牌/底纹**（100 多个文件）。若只写
"必须为 0"，这一轮就红；若写"不许变多"，就能**一轮一轮往下压**：

```dart
const _baseline = {'HudTokens': 133, 'ListTile(': 102, ...};  // 只许往下调
const _floors   = {'DesignScaffold(': 46, 'DesignRowTile(': 98, ...};
```

每轮迁完把 `_baseline` 改小。**数字被调大就是明着退步**，评审一眼能看见。

### 4.23.2 ★ 全局删 import 之前先按"谁在引用组件"反查

我为了清 `field_backdrop.dart` 的未用导入，直接全局删了这条 import ——
结果 **46 个文件仍在用 `FieldBackdrop(`**，`analyze` 一次报 53 个 error。
正确顺序：**先 `grep 'FieldBackdrop('` 拿到引用集**，只在"没有引用"的文件里删导入。
同理适用于任何"清导入/清组件"的操作：**先查引用，再删声明**。

### 4.23.3 组件名替换要前缀感知（r488 的坑，r489 复用正则）

`(?<![A-Za-z_])ListTile\(` 才不会误伤 `SwitchListTile(` / `CheckboxListTile(`。

## 4.24 r490：评审接触表 ＋ 令牌清扫的两个替换陷阱

### 4.24.1 `review_sheet.py`：153 屏一屏一格

评审时不要一屏一屏翻 `index.html`。`python3 design/review_sheet.py --png` 出一张
1400×6600 的接触表（8 列 × 20 行，暗色中文为主），页头印着"评审四问"。
发现哪格不对再点回 `index.html` 看 4 变体大图。

### 4.24.2 ★ 字段替换必须"长名先于短名"

`hud.glass` 是 `hud.glassStrong` 的前缀。按 dict 顺序替换会先命中短名，
生成 `DesignPalette.surfaceStrong`（不存在）。**排序后替换**：
`glassStrong → glass`、`edgeWidth → edge`、`blurChrome → …`。

### 4.24.3 ★ 不要顺手把变量名 `hud` 改成 `p`

`p` 在页面里常已存在（如 `CloudProviderInfo p`）⇒ `duplicate_definition`。
**只换类型名和字段名就够了**，变量沿用 `hud` 不影响可读性（它已经是 `DesignPalette`）。

## 4.25 r491：令牌清扫收口 ＋ 三个"类型不是颜色"的陷阱

把 `HudTokens` 从 107 个文件清到 **1**（只剩 `design_preview_page.dart` 这个**设计样张**）。
机械替换在 `notes/files/drive/photos/chat` 上都能一遍过，但有三处**类型不是 Color**：

| 令牌 | 真实类型 | 错误写法 | 正确写法 |
|---|---|---|---|
| `blurChrome` | `double`（模糊半径） | `blur: p.surface` | `blur: 16` |
| `glowShadow` | `List<BoxShadow>` | `shadows: p.primary` | `shadows: [BoxShadow(color: p.primary.withValues(alpha:.35), blurRadius: 12)]` |
| `edgeWidth` | `double`（描边粗细） | `width: p.line` | `width: 1` |

★ 还有一条**不会让 analyze 红**的坑：`theme.extension<DesignPalette>()?.meta`
这类"扩展取色助手"里的 **getter 名也重命名了**（`meta→dim`、`warning→danger`）。
漏改时编译通过、运行时拿到 `null` 静默退回系统色 —— **改令牌必须连取色助手一起 grep**。

## 4.26 r491：批量换行卡时，**`dense` 与"非图标前导"是设计系统的两道暗门**

* `dense` 曾经只透传、行高恒 62 ⇒ 目录/权限选择器这类长清单滚不动（用例红）。
  现在 dense 真的更紧凑（48 高，上下 2+6，内边距 6）。
* 前导内容曾被强制 `40×40` ⇒ 日历"时间 + 竖色条"（52 宽）溢出 4px。
  现在只给**最小** 40×40，宽度由内容决定（右留 12）。
* 反向断言请照旧查旧组件（`findsNothing(ListTile)`）：把反向断言也改名 =
  把"没有老形态"变成"设计组件不存在"，是**假绿反转**。

## 4.27 r492：**删"类边界"代码前先盘点公开类**；底纹退役要连订阅一起想清楚

* 我按"第一个绘制类"把 `field_backdrop.dart` 截断 ⇒ 文件**末尾的 `HudScaffold`
  一起没了**，`backdrop_legibility_test` 6 条当场红。
  规矩：删之前 `grep '^class '` 列出全部公开类，删之后**再列一次对比**。
* 底纹退役只删"画什么"，**不删动效订阅**：`ambient_clock_test` ④⑤ 钉的是
  "可见页面占一个订阅位、不可见页面不占"，与绘制无关 —— 一起删会让判据变空。
* 行卡只允许一套几何：新增 `DesignRowShell`（外 16/5、圆角 13、最小 62、内 20/10），
  自定义行（文件/聊天）也必须套它，否则同屏两种圆角两种边距。

## 4.28 r493：全局默认值比单页改动影响面大得多（`AppBarTheme.shape`）

* AppBar 的"尺子"挂在 `AppBarTheme.shape`（`HudBarBorder`）上，**一改全 App 生效**。
  退役它 = 聊天/设置/文件/相册所有页头同时变干净；这类"全局默认值"改动必须
  **单独截一张真机像素**确认没有把某页的层次压塌。
* 装饰与信息的界线：未读态原来用「左侧能量条 + 辉光」表达，现在换成
  `selected`（主色淡底 + 主色描边）+ 加粗标题 + 未读角标。
  **删装饰时先问：这条信息还有没有别的承载？** 有才删，没有就换成设计语言里的承载方式。

## 4.29 r494：ARB 补丁别让 `re.sub` 吃掉 JSON 转义；"退役一个效果"要连控件一起退役

* 改 ARB 的替换串必须传 **函数**（`lambda m: ...`），否则 `json.dumps` 产出的 `\n`
  会被 `re.sub` 当转义解释，写进文件的是**真换行** ⇒ 非法 JSON、`gen-l10n` 报错。
  改完立刻 `json.load()` 自证一遍。
* **效果退役 ≠ 只删实现**：r492 退役底纹后，设置页的开关成了"拨了没反应"的死控件。
  规矩：退役一个效果时，把**控件、档位摘要、帮助文案**一起清掉，并在用例里
  钉成"它必须**不在**"（`DA136`）。
* 亮色主题此前只在测试字体下验过；**真机像素**才算证据（本轮四页）。

## 4.30 r495：批量重构的三条自证；"删掉外层"必须问"这层原本提供了什么"

* **括号配对只认 `() [] {}`**：第一版把 `<` `>` 也算进去（想处理泛型），
  在 `a < b` / `List<int>` 处错位，**把 41 个文件改坏**（180 个 error）。
* **每次替换自证括号平衡不变**：`balance(新) == balance(旧)` 才算成功，
  否则跳过并记下（本次第二版就靠这条把 1 处无法安全处理的调用点留给人工）。
* **改前快照**：`cp -R lib/src /tmp/rNNN_bak/src_snapshot` —— 没有 git 时这是唯一回滚路径。
* **拆一层之前先问这层提供了什么**：`FieldBackdrop` 拆掉后 `HudScaffold` 露黑底
  （亮色对比度用例量到 L=0.000）。"我不需要它的绘制了" ≠ "我不需要它的底色"。

## 4.31 r496：同一个词在页面上出现两次 = 用例歧义判据

* 把相册页头副标题从 `SYNOLOGY PHOTOS · 个人空间` 改成 `个人空间` 之后，
  `find.text('个人空间')` 从"唯一命中空间芯片"变成两处命中 ⇒ 两条用例红。
  规矩：**新增/改写文案前先想"这个词页面上还有谁在说"**；要么改文案，要么给身份 Key。
* 去 HUD 遥测字的三条判据：① 不许全大写产品名；② 不许 `letterSpacing ≥ 1.0`；
  ③ 颜色/字号必须走 `DesignType` / `hud.muted`。守卫只看**代码行**，注释不算实现。

## 4.32 r497：页头用例要盯"类"，不要盯"文件"；`Column` 会偷偷居中

* 外壳页头删掉 `DRIVE/WORKSPACE/PROFILE` 遥测代号后，我写了"这个文件里不许出现
  `TelemetryLabel`"的守卫 —— 立刻被 **Me 页的 NAS 地址**误伤。
  那个地址是**信息**（改成设计令牌保留），不是装饰。
  规矩：**判据锚在"类"上**（`_TabTitle` 的类体），不要锚在文件上。
* `Text` 放在 `Column`（默认 `crossAxisAlignment: center`）里，会**按自身宽度居中**。
  Workspace 标题真机就是居中的，而 Files/Chat 是左对齐 —— 同一外壳里两种对齐。
  修法：`SizedBox(width: double.infinity)`；判据钉在"必须撑满宽度"。

## 4.33 r498：**半透明叠加色在亮色下会塌成底色** —— 判据必须在两套主题上各看一眼

* `containerHigh@0.4` 这类"叠一层 40% 灰"的写法，在**深色**下能拉出层次，
  在**亮色**下 containerHigh 本身就接近底色 ⇒ 卡片边界消失。
  规矩：卡片/输入框一律用 **`surface` 底 + 1px `line` 描边**，不要靠"半透明叠色"造层次。
* 守卫要能拦回退：外壳代码里**不许出现 `surfaceContainerHigh`**，且必须出现
  `DesignPalette...line`。
* "深色下没问题"**不能**作为"亮色下也没问题"的证据（这条坑隐藏了至少两轮）。

## 4.34 r499：`Clip` 的位置决定"裁的是谁"；窄图会暴露它

* `ClipRRect(child: Center(AspectRatio(...)))` 在 `Stack(fit: expand)` 里，
  裁剪框 = **整格**；图片比格子窄时，图片的角**根本不在裁剪边上** ⇒ 圆角形同虚设。
  规矩：**圆角要套在"图片自己的框"里**（`AspectRatio` 内层），不是套在格子上。
* 第一版修法上线后我按像素复核发现"完全没变" —— **"改了"不等于"改对了"**，
  像素判据（左边缘 `x` 是否随 `y` 递增）才是结论。
* 报告措辞也要自查：上一轮我写"圆角不一致"，实际是"圆角没生效"，两件事不同。

## 4.35 r500：诊断标识上了主界面，会同时毁掉排版和隐私

* `conn_id`（形如 `bD2WEjbkkksq4Mg5Bvnm`）被拼进频道列表页头的链路行：
  真机上这一行**折成两行**，第二行只剩一个 token —— 排版坏了；
  而且它是一个**连接标识**，会被截图带走 —— 隐私也坏了。
  规矩：**诊断串只进 logcat**；页头最多写"已连接 / 同步中 / 离线"。
* 判据要能拦回退：代码里不许出现 `chatStatusConnSuffix(sync.connId`；
  l10n key **保留**（删 key 会误伤未知调用方）。

## 4.36 r501：同一个"字"在界面上有两个来源，才算干净

* 聊天元信息原本有 **9 处** `AppType.telemetry(...)`（mono 字体 + 字距 0.6，三种字号）。
  它是"遥测字"——上一版 HUD 的遗产；设计语言的次级文字只有
  `DesignType.labelSmall/bodySmall` 两档。**一套界面里同一种信息只该有一套字号**。
* `HudChip` 的切角（`ChamferBorder`）是"仪表标签"造型；系统消息本质是**提示**，
  用胶囊 + 1px 描边最稳（浅底上也有边界）。**造型要跟信息性质走，不跟旧组件走**。
* 判据要能数出来：`AppType.telemetry(` 从 9 → 0、`ChamferBorder(` 从 1 → 0。

## 4.37 r502：等宽字只有在"它是代码/数字对齐"时才有理由

* 聊天家族里 `TelemetryLabel` / `AppType.telemetry` 的残留，绝大多数**不是**代码：
  日期、时间戳、打字指示、附件大小、分组状态 —— 它们是**内容**。
  逐处换 `DesignType.labelSmallSize`，颜色换 `hud.dim/line/primary`。
* **唯一保留**的是链接预览的 `snippet`（等宽是语义）。判据写成"三份文件里计数为 0"，
  而不是"全仓为 0" —— 这样才既拦住回退，又不误伤代码文本。
* 分隔线只该是"收窄的细线 + 内容字"，不该是带字距的仪表读数。

## 4.38 r503：令牌要"成对量"，只量暗色会把亮色的错放过去

* `surface2` 在暗色是 `#243040`（对 `#0B0E12` 分得开），在亮色是 `#E8EEF6`（对 `#F2F5F9` **几乎同值**）。
  只在暗色看图 ⇒ 判断"胶囊清楚了"；一到亮色，胶囊的形**直接消失**。
  规矩：**凡是"底/面"类令牌，改完必须两套主题各量一次像素**（页面底 vs 控件内部）。
* 像素取样要取"控件内部"，不是"我以为的位置"：本轮我第一次量到 `(241,245,250)`
  其实是**两条胶囊之间的空白**，差点得出"改了没生效"的错误结论。
  判据要能自证位置（先沿列扫一遍，找到 255 的横带再说）。
* 主题切换的老坐标会随版式失效：这轮 `(500,1461)`/`(260,2416)` 已经点不到，
  必须按当轮截图**反算**（乘 ≈1.2545）。

## 4.39 r505：主题是"清单式"覆盖，漏一项就有一块外来材质

* `AppTheme._build` 给了 AppBar / Chip / Button / ListTile 主题，**唯独漏了 `popupMenuTheme`**
  ⇒ 全仓所有 `PopupMenuButton` 都是 Material 默认（灰紫底 + 4px 圆角）。
  这类漏项在暗色下不显眼，**一亮就露**。
* 规矩：**按"组件家族"对表**，不是按"我记得的组件"对表。弹层至少三族：
  菜单（`popupMenuTheme`）、底部弹层（`bottomSheetTheme`）、对话框（`dialogTheme`）。
* 取样换算：截图预览宽（920）≠ 原图宽（1148），按预览坐标取样会落到控件外，
  会得出"改了没生效"的假结论。

## 4.40 r506：主题按"组件家族"对表；"改了没变化"先问这条路径归谁管

* r505 补了 `popupMenuTheme`，r506 又把 **6 个控件家族**（开关/复选/单选/滑杆/
  分段按钮/提示条）补齐 —— 它们此前全走 Material You 种子色，与设计令牌是两套蓝。
  **对表清单**：AppBar · BottomSheet · Dialog · SnackBar · ListTile · Divider · Card ·
  Chip · Input · 四种 Button · NavigationBar · TabBar · Progress · **PopupMenu** ·
  **Switch/Checkbox/Radio/Slider/SegmentedButton/Tooltip**。
* ⚠️ **"改了没变化"要先问"这条渲染路径归谁管"**：设置页开关改主题后像素**逐字节相同**，
  因为 `DesignSwitchRow` 自己传了 `activeTrackColor`。这不是补丁失效，是**主题管不到它**。
  判据：先找该控件的实际构造点，再谈主题是否生效。

## 4.41 r507：一处改完要 grep 全仓同类；批量替换要先按行过滤注释

* r506 在日历页去掉 `letterSpacing: 1.2` 后只改了一页 —— `grep` 全仓其实还有 **12 处**
  同款"全大写 + 加字距"仪表标签。**同一种错几乎不会只出现一次**：
  改完一处立刻 `grep` 该写法，按"同类全清"处理（守卫 `DA150` 现在会盯住）。
* 可量收益：`drive_more` 副标题从 `SYNOLOGY DRIVE · Recyc…`（截断）变成完整 —— **加字距真的在吃宽度**。
* ⚠️ 批量正则 `re.sub(r'letterSpacing: 1\.2,?\s*','')` 把注释里的同字样也吃了
  （注释被吃成 `去掉 ``）。**规矩**：批量替换前按行过滤，只对**代码行**生效；
  改完 `grep` 一遍注释是否被伤。

## 4.42 r508：全大写品牌码与"诊断串当文案"是同一族的最后一批

* 设计语言里没有"全大写代号"这一层：`SYNOLOGY CALENDAR` / `SYNOLOGY DRIVE · …` /
  `SYNOLOGY OFFICE · …` / `SYNOLOGY CONTACTS · …` 全部改成正常大小写的品牌句
  （`Synology …`）。改完副标题还变短了 ⇒ 原来被截断的那行恢复完整。
* 设置页那条 `SVC ON · CONN <conn_id> · SOCKET READY …` 是**诊断串**，
  和 `DA142`（聊天页头印 conn_id）同一个病：**诊断信息不是用户文案**。
  界面只回答"能不能用"（一句人话），细节留日志。
* ⚠️ 改文案会牵动**断言原文的老用例**（本轮 3 个文件）。规矩：
  **改期望值可以，改判据不许** —— "宽屏完整显示 / 手机整行不画"这类语义判据一条都不能松。

## 4.43 r511：`Colors.grey` 是"不随主题变"的同义词

* 设计令牌里没有 `grey` 这一档：次要文字是 `dim`，更淡是 `muted`。
  裸 `Colors.grey` 在亮色下压白底几乎看不见、暗色下又比 `dim` 亮 ⇒ 同一句提示在两种主题里
  层级不同。判据用**像素**：`(158,158,158)` 是 Material 原值，`(127,136,149)` 是 `dim`。
* **例外要说得清**：Office 画布画"白纸"，纸上的灰是**文档墨色**，与 App 主题无关 —— 这不是放宽。
* 守卫写 `Colors.grey` 为 0 时**必须过滤注释行**（上一轮已经踩过注释被算进正文的坑）。

## 4.44 r512：换组件皮会打红"按类型找控件"的用例 —— 这是用例的问题，不是换皮的问题

* 37 处 `SwitchListTile` → `DesignSwitchRow` 之后，7 个用例文件全红，原因是它们
  `find.byType(SwitchListTile)` —— **断言了实现类型**。仓库早备着
  `test/support/switch_rows.dart`（两种类型都算的 finder），本轮统一改用它。
  **判据一条没松**：值有没有翻转、原生拒绝时不许翻、无权限时不渲染，逐字未改。
* 换组件前先**逐参数对 API**：37 处只用到 8 个参数，全部在 `DesignSwitchRow` 上存在 ⇒
  机械替换即可；只要有一个参数缺席，就得逐个手改调用形态。
* 棘轮基线**当轮就要收紧**（23 → 1），否则下一轮又会悄悄长回来。

## 4.45 r513/r514：勾选行换皮 + "组件别盖主题"（以及一次被像素否掉的判断）

* 15 处 `CheckboxListTile` → `DesignCheckRow`：参数逐个对过（`controlAffinity` 组件没有，
  设计稿的勾选框固定在尾随位置，直接删）。换 `onChanged` 签名后 `v ?? false` 会变成死代码，
  `flutter analyze` 会报 `dead_null_aware_expression` —— 换皮时顺手清掉。
* **组件不许盖主题**：`DesignCheckRow` 里显式 `side: BorderSide(color: p.line)` 盖掉了
  `checkboxTheme.side = dim` ⇒ 同一控件两个颜色来源。删掉显式值，主题权威。
* ★★ **判断被像素否掉时要撤回，不是解释掉**：我原写"一处看得见、一处几乎看不见"，
  按 A/B 拍下来**两帧同区域逐字节相同** ⇒ 那句不成立，已从结论文本删除，
  状态档也从"真机复验"降到"真机不适用"。证据照样留在 `docs/evidence-r513/`。

## 4.46 r516：动态取色（Material You）会把"两套主色"摆在同一屏上

* 本机的「Dynamic color」是**开**的 ⇒ `colorScheme.primary` 是壁纸算出来的灰蓝
  `(80,103,146)`；而设计系统的主色是**令牌** `#2563EB`。`OrbButton` 当时读的是
  `scheme.primary`，于是右下角那个 `+` 比同屏的 chip / 文字暗一档 —— 看起来像"没点亮"。
* 规矩：**设计组件只认令牌**（`DesignPalette.*`），不读 `colorScheme`。
  阅读顺序是"先问这个颜色谁说了算"，不是"能不能编译过"。
* Material 自带组件（Extended FAB / TextButton / SnackBar）仍走 `colorScheme` ——
  要不要整体支持 Material You 是**产品决定**，不是设计令牌能单方面定的。

## 4.47 r517：同一个视觉问题可能要在"两层主题"都钉

* `DesignTheme`（`design_palette.dart`）只包住 `DesignScaffold` 的子树；
  裸 `Scaffold` 的页面（如 `notes_page`）拿到的是 **`AppTheme`**。
  我只改了前者，装到真机上**一点没变** —— 修完像没修。
* 规矩：改"全局外观"主题项（FAB / SnackBar / Dialog 这类）先问一句
  **"这个页面过不过那层 Theme"**，两层都钉，用例也**两条腿一起断言**。
* 配套事实：`design/synhub_ui/generate.py` 的 `fab()` 只有一种配色
  （`primary` 实心 + `onPrimary` 图标）⇒ 组件不许自己发明容器色。

## 4.48 r518：动态取色只能管"色相"，不能管"中性色/语义色"

* 打开了 Material You 之后，`colorScheme.error/outline/surfaceContainerHighest`
  全是壁纸算出来的。features 里有 **332 处**直接读 `colorScheme.*`，
  于是"错误红 / 分隔线 / 次级底"这三样每个用户都不一样，与 154 张设计稿对不上。
* 结论：**中性色与语义色归令牌，色相留给壁纸**（`primary` 是否也收归，
  是"要不要保留 Material You"的产品决定，设计侧不能单方面定）。
* ★ 连带效应要一起看：`onSurfaceVariant` 换成令牌 `muted` 后，
  `HudTokens.meta` 的 0.78 透明度让亮色对比度掉到 3.1:1 —— 既有对比度守卫当场打红。
  **改一个槽位的值，先 grep 谁乘了透明度。**
* ★ 改主题槽位常常**没有可隔离的像素差**（页面本来就全走令牌）。这时证据是
  "槽位 + 真渲染出来的解析值 + 对比度守卫"，不要硬凑 A/B，状态档也不写"真机复验"。

## 4.49 r520：判据要钉在"可用高度"，不是"我以为的那个分支"

* 日历空态在真机上被下边缘截断、右边被 FAB 压住。我第一版按"紧凑布局（`tight`）"
  分支改的 —— 装上真机**一点没变**，因为真机走的是**非紧凑**分支
  （预算够，只是**下半区本身矮**：日历网格 + 环境卡把上面吃满了）。
* 第二版把判据换成**可用高度**（`avail < 640` ⇒ 一行提示并给 FAB 让 96；
  `≥640` ⇒ 整块空态）才生效。★ 教训与 §4.47 同源：**先问"真机到底走哪条分支"**，
  不要按"最像缺陷的那条分支"去改。
* 配套：来源名里的"多少国 / 哪些节日"是**文档**不是文案 —— 与 §4.x 的
  "诊断串不许当用户文案"一族；ARB 里就该只有名字。

## 4.50 r521：悬浮按钮的验收帧只能取"滚到底"

* 相册时间轴的最后一行被「上传到 timeline」压住 —— 但**滚到顶那一帧看起来也"被压住"**，
  而那是悬浮按钮的正常行为。判据只能取**滚到底**那一帧（footer 与最后一行都在按钮上方）。
* 反面：拿顶上那帧"证明"缺陷，等于把通用行为当 bug；拿它"证明已修复"，等于没验。
* 顺带：列表尾巴的高度要按 **FAB 高 + 外边距 + 留白** 算（这里是 56 + 16 + 32 = 104），
  不要拍一个"看起来够大"的数。

## 4.51 r522：黑底页面必须**显式**接管顶栏/按钮的前景

* `AppTheme.appBarTheme.titleTextStyle` 把标题色钉成 `onSurface` —— 黑底查看器只写
  `foregroundColor: Colors.white` **不管标题**（那只影响图标）⇒ 亮色下深墨蓝画在黑上。
* ★ 更要命的是**自己修出来的连带**：`DA159` 把全局 FAB 前景钉成 `onPrimary`（白），
  于是任何"把 FAB 底色改成 `surface`（亮色=白）"的站点变成**白底白字**。
  规矩：**改全局前景色时，必须 grep 所有自己设 `backgroundColor` 的站点**（这次三处）。
* 判据都做了反向验证：删掉修复 ⇒ 用例必须变红。

## 4.52 r523：`Expanded` 里的"说明标签"在被挤压时只会换行

* 相册排序行 = 标签（`Expanded`）+ 两颗 chip。英文下 chip 变宽 ⇒ 标签拿到
  的宽度不够 ⇒ 换行成两截（"Album"/"sort"），整行高度翻倍。
* 判据：**`Expanded` 里的文字必须有 `maxLines`/`ellipsis` 或干脆不该在那儿**；
  这次选了后者 —— 标签冗余（chip 已表意），语义搬进 `Semantics`。
* ★ 换语言 = 换宽度：任何"中文刚好放得下"的行，英文都可能崩；反之亦然。

## 4.53 r524：`Badge` 的矩形是 child 的矩形 —— 量错对象就永远绿

* 判"徽标位置"时 `tester.getRect(Badge)` 拿到的是**图标按钮**的矩形，
  `offset` 只移动**数字**那颗小圆 ⇒ 断言恒绿（第一版就是这么错的）。
* 改成量数字后仍然两向都绿：**800 宽下 AppBar 内边距不足以把徽标推出去**，
  widget 环境复现不了真机偏移 ⇒ 这条**没有可信的 widget 守卫**，只有真机像素。
* ★ 规矩：用例绿不代表它有区分力；**必须做一次"删掉修复看它红不红"**，
  不红就老实写"这不是守卫"，别拿它当证据。

## 4.54 r525：`tonal` 按钮的底色跟壁纸走 —— 黑底页面上一律不许用

* `secondaryContainer` 由**壁纸种子**派生：亮色是淡紫。放到纯黑的查看器里就是
  一条通栏浅色板子，和"白标题 + 白图标"的 chrome 不是一套语言。
* 规矩（与 §4.51 同源）：**黑底容器内的按钮只用 `primary`/`onPrimary`**，
  不许 `tonal*`；浅色卡片上 tonal 仍是正常用法（音频播放键就是）。
* 守卫写源码契约时要**跳过注释行** —— 第一版把注释里的 `tonalIcon` 也算违规，
  一提交就红。

## 4.55 r532：`Positioned` 只给 `left` ⇒ 文本宽度**无界**，`ellipsis` 永远不触发

* `Positioned(left: x, child: Text(..., overflow: ellipsis))` 看着"有省略号"，其实
  **父约束无限** ⇒ 文本按自然宽度铺出去，被屏幕右缘**硬裁**，省略号根本走不到。
  长句提示必须 `left` + `right` 都给，并允许 2 行（`TelemetryLabel` 已加 `maxLines`）。
* ★ 写守卫时先自问"删掉修复它还绿吗"：本轮几何断言在**中文 locale + 800 宽**下
  **两向都绿**（中文短，挤不出屏），真守卫只能是**源码契约**（`right:` 在场），
  已做反向删除验证。同一缺陷两次假绿教训（DA167 / DA169）都记在这条下。

## 4.56 r533：判断"提示被截断"要分成**两族**

* **无界族**（DA169）：父约束无限 ⇒ 文本铺出去被硬裁，`ellipsis` 不触发。
  成因为 `Positioned` 只给 `left`（或 `Row` 里没 `Expanded`）。
* **有界族**（DA170）：父约束正常、老实加了省略号，但 `maxLines: 1` ⇒ 整句变半句。
  短代号用 1 行是对的，**整句提示必须 2 行**。
* 扫这类问题先机检再人看：脚本扫「`Positioned` 只给 left 且块内有 `TelemetryLabel`」，
  本轮 32 个长文本调用点里只有 1 个命中且是误报（`file_row` 的锁图标）。
* ★ 量具宽度要等于真机可用宽度：第一版用 300 宽判"两行放得下整句"⇒ 直接红，
  换成 **358**（390 − 两侧 `Gap.md`）才对。

## 4.57 r536：★★ 写进证据之前，先量一次**前台包名**

两轮（r534/r535）我把华为浏览器里的第三方阅读站当成 SynHub 的"阅读器"评审了一遍，
还量了对比度。发现方式是返回时突然出现一个完全不相干的应用。

* **判据**：`adb shell dumpsys activity activities | grep mResumedActivity`
  → 只认 `com.openviewai.synhub/.MainActivity`；不是它就不许写结论。
* **为什么会错**：从本 App 点出来的东西完全可能是外部 App/浏览器（"用其他应用打开"、
  网页里的 `target=_blank`、站点自己的弹层）。
* **旁证**：把页面上的文案 `grep -rn` 一遍 —— 本仓搜不到的串，就不是我们的 UI。
* 教训归属：仪器⑰（"判前台只认 `mResumedActivity`"）早就写了，**是没执行**，
  所以这条的价值不在"新知识"，而在"每屏都量一次"的动作化。

## 4.58 r537：`outline` 是**边框**色，不许拿来当文字色

* Material 的 `outline` / `outlineVariant` 是画**边框/分隔线**的；拿它当文字色，
  在浅色主题下对比度可能低到 **1.15:1**（r537 实测：页码 #E0E6EE on #F1F5FA）。
* **文字**一律 `onSurface` / `onSurfaceVariant`；要"弱化"就用 `onSurfaceVariant`，
  别用更浅的语义色。
* 判据：**量对比度**（对底色 ≥ 3:1 用于大字号/图形，≥4.5:1 用于正文），
  不要断言"用了哪个常量"。

## 4.59 r538：撞见一处 ⇒ 立刻**扫全仓**，并把判据固化成静态守卫

* `DA171`（缩略图页码）只是"撞见的那一处"；顺着查下去，`outline` 当**文字色**全仓
  **20 处**（两套主题下 1.26–1.27:1）。
* 扫的时候要**分类**：`Border*`/`Divider`/`decoration` = 边框（合法）、
  `Icon(`/`icon:` = 图标（另一码事）、`Text(`/`textTheme`/`copyWith(` = 文字（要改）。
  还要排除 `Icons.lock_outline` 这类**图标名**与注释行。
* 守卫要能**自证**：用例里构造一个坏样本必须被抓到、两个好样本不许误报；
  再**反向**把真代码改回旧写法看它红不红（本轮实测逐字点名 `nas_manager_page.dart:293`）。
* 只测量、不动的地方要写清：**图标**也用 `outline`（空态大图标更淡是不是设计取向？）——
  这类"看着像问题但属设计选择"的，记读数、不擅自改。

## 4.60 r539：令牌合格 ≠ 用法合格；**量具自己要先自证**

* 先给令牌做体检（两套主题逐条算对比度）：`text 17.85 / muted 5.45 / dim 5.50 / primary 5.17`（亮），
  `14.07 / 6.40 / 4.63 / 5.17`（暗）—— **都合格**；`line` 1.26 只配画线。
  所以别急着改令牌，先查**用法**：`withValues(alpha:…)` 会把任何合格色压到不合格
  （`dim@0.5` → 2.09:1）。
* ★ **量具 bug**：临时脚本把 `0.2126*r + 0.7152*f(g) + 0.0722*f(b)` 写成了
  g/b 二次线性化 ⇒ 同一对颜色报 2.96 而正确是 4.57。**发现方式是手算对照**。
  规矩：新写一个对比度函数，先跑 `黑/白 = 21:1` 自证，再拿去出数。

## 4.61 r543：**"看起来不对"≠"缺陷"** —— 空白页要回读原始字节

* 阅读器第 2 章只有标题、下面空白。先记"未判定"，**回读原始 epub** 才下结论：
  这份合成书的 `nav.xhtml` 里第 2、3 条目录**指向同一片段** `ch2.xhtml#sec`，
  于是第 2 章 = 到锚点之前（只有 `<h1>`）、第 3 章 = 锚点之后 ⇒ **与文件一致，不是丢内容**。
* 规矩：判"某页空白/少内容"，**必须拿到原始字节对照**（下载回读、解包、看目录/锚点）；
  没有原始件时只能写"未判定"，**不许先登记缺陷再找理由**。
* 顺带：真书不会出现"两条目录同一锚点"；遇到这种样本先怀疑**样本**，再怀疑解析。

## 4.62 r543：往文档里插段落，锚点要带**足够长的前缀**

踩了一次：想插在 `### 6.13` 之前，锚点写成 `## 6.13 …` —— 它是 `### 6.13` 的**子串**，
结果把三级标题劈成 `#` + 正文 + `## 6.13`，标题降了一级、守卫当场红（`§6.13 不见了`）。

* 插段落的锚点一律带**完整行前缀**（`\n### 6.13` 而不是 `## 6.13`）；
* 改完立刻跑**读这份文档的守卫**（这里 `test/defect_id_namespace_test.dart` ①），
  它会明确报"`### 6.13` 不见了"——比肉眼看快得多；
* 判据：**改文档也算改代码**，同样要"改完就跑守卫"。

## 4.63 r545：守卫扩面时，先让它把**已知的好样本放过、坏的抓住**

* 给守卫加"图标也要查"时，自证用例立刻红：扫描器对含 `Icons.` 的行**整行跳过**
  （本意是躲 `Icons.lock_outline` 这种**图标名**），结果把"图标颜色用 outline"整类漏掉。
  改法：先 `Icons.\w+ → <icon>` 再判断。
* 修好后的守卫抓出**第 12 处**我手工分类漏掉的（`Icons.lock_outline` 那行）——
  **守卫比眼睛准**，扩面之后要立刻重跑一次全仓，别假设"我列全了"。
* `outline` 这条规则现在**同时管文字与图标**：它是边框色，两套主题下 1.26/1.27:1。

## 4.64 r548：写补丁脚本的守卫阈值要**先量再设**（又踩一次）

给 `design/START-HERE.md` 打补丁时写了 `assert len(out) > 2000` 当"拒绝写可疑内容"，
而那份文档只有 **1781** 字符 ⇒ 断言失败、**补丁整段没落盘**（文件没坏，但白跑一趟）。
这正是 AGENTS §1.6.2 记过的那条：先 `print(len(s))`，再设阈值。

另：本轮把一直在说的「25 个模块」按 `unit` 第 4 段复算，订正为
**153 屏 = 24 个模块 + 1 张跨模块样例**（`photos_grid.json` 的 unit 明写"不计入 160 台账"）。
— **自己写过的数字也要复核。**

## 4.65 r549：**手写汇总数字必须由机器校验**，否则一定会漂

* 总账表头写 `162/10`，逐行真值是 `163/12`（差在手工加减 + 新登记没同步）。
  守则：**凡是"表头/摘要里的计数"，都要有一条用例按明细重算并对账**；
  本轮给 `defect_closure_test.dart` 加了第 ⑨ 条，并把"改回错值"反向验证过。
* 加守卫的顺序也要对：**先按明细订正数据**（让真值出现），**再加断言**（让未来漂移变红）。
  反过来会把"当前错误"固化成期望值。

## 4.66 r549–r550：同一个"写入守卫阈值"连踩三次

三份新文档（`START-HERE.md` 1792 字符、`evidence-r548/README` 1367、
`final-report` 2661）都被我写成 `assert len(out) > 3000/2000` ⇒ **补丁三次没落盘**。
一直以为"文件没坏就行"，其实**白跑三趟**，而且每次都以为已经改好了。

铁律：**写补丁脚本第一条语句就 `print(len(s))`**，阈值只写"比原文短太多才拒绝"
（`len(out) > len(s) - 200`），或者干脆只断言 `old` 出现次数与 `out` 非空。

## 4.67 r550：**动态取色不是"接线"，是"取不到"**；色相层只能借色相

* 现象：设置里写着"跟随系统壁纸"，界面却永远是品牌蓝。根因不是开关没接，而是
  `DynamicColorBuilder` 在 **EMUI + 动态壁纸**的机器上恒为 `null`（`WallpaperColors`
  与 `WallpaperManager.getDrawable()` 也都拿不到）⇒ 必须另找来源：
  `android:color/system_accent1/2/3_500` 才是这类机器唯一拿得到的调色板。
* **"跟随壁纸"要落到像素**：改前/改后同坐标取样（头像 `#465E8C`→`#336383`），
  否则"看起来变了一点"不能算证据。
* 色相层（`HudDynamicHue`）**只换 `primary/primarySoft/accent`**，中性/语义色照令牌
  不动（`DA160`）；关掉时**不挂扩展** ⇒ 154 稿逐字节不变。
* 新增平台通道会被 `method_channel_gate_guard_test` 当场抓住：要么真门控，
  要么在**调用点**写 `gate-exempt: <登记名>` 并在测试里登记理由（光在测试里加名字不够）。

## 5. 诚实边界

* 生成的是**界面骨架**：布局 / 组件 / 文案 / 令牌 / 点击区全齐，**业务数据与状态管理不生成**（留注入点，手写接线）。
* 复杂交互（视频手势、地图、PDF 阅读器、图表）需要先加新的 spec 节点类型，再出稿 —— 每加一类约一次改动，不是每次从零。
* 「每个平台」：Flutter 一套代码覆盖 Android/iOS/桌面/Web；本仓库**只构建 Android arm64**，故以 Android 为验收面。
* 目前 **160/160 个台账单元**都有着落：**153 个界面单元出稿**（共 153 份 spec，跨模块样例另计
  `photos_grid`）＋ **7 个非界面单元**登记在下面「非界面单元」表里：
  * **audio 11/11 已出齐**（音乐库 / 单曲页 / 网络电台 / 专辑详情 / 收藏 / 搜索 / 服务端队列 /
    发现 / 均衡器 / 远程播放器 / Chromecast 不可用）；
  * **files 18/18 已出齐**（文件浏览 / 预览 / 搜索收藏分享 / 目标目录 / 挂载 / USB / WebDAV /
    Office 入口与文档 / 后台任务 / 版本历史 / 共享 / 更多 / 按需下载 / 标签 / 继续阅读 / DJVU 不可用）；
  * **photos 14/16 已出齐**（照片时间线 / 最近添加 / 大图页 / 照片工具 / 标签 / 相册设置 /
    手机备份 / 释放空间 / 后台任务 / 迁移状态 / AI 美化 / 照片地图 / 睡眠备份 / 相册管理员页）；
    其余 2 个单元无独立界面，已在下面的「非界面单元」登记，不画假界面；
  * **downloads 12/12 已出齐**（任务列表 / 新建 / 任务详情 / 选择文件 / 设置 / BT 搜索 /
    eMule 列表与搜索 / eMule 服务器（管理员）/ 内置浏览器 / RSS / 验证码）；
  * **chat 15/15 已出齐**（频道列表 / 频道消息（气泡+置顶+输入条）/ 频道内容五 tab / 跨频道内容面板 /
    话题 / 订阅话题 / 成员 / 已读未读 / 媒体与文件 / 定时与提醒 / 新建频道 / 标签 /
    可加入频道 / 归档 / 附件查看）；
  * **drive 21/22 已出稿**（我的文件 / 更多 / 分类浏览 / 收藏集 / Computer / 已连接设备 /
    复制到 / 请求文件 / 本地文件 / 通知 / PDF 批注 / 存储空间 / 保存为扫描件 / 搜索 /
    同步任务 / 团队成员 / 团队回收站 / 纯文本编辑 / 回收站 / 高级共享 / Drive 管理）；
    余下 1 个 `drive_pdf_text_layer` 是 PDF 文字层助手，无界面，登记在下面的「非界面单元」；
  * **notes 21/22 已出稿**（笔记列表 / 笔记本 Shelf / 笔记查看 / 编辑 / 待办与新建待办 / 标签 /
    智能笔记本 / 快捷方式 / 共享与加入 / 我分享的 / 共享设置 / 回收站 / **冲突裁决（新 `compare` 版式）** /
    手绘 / 从 NAS 选图 / 高级搜索 / 全文搜索 / 后台同步 / 逾期提醒 / 版本历史）；
    余下 1 个 `note_body` 是正文渲染组件（只读 Quill 封装），无独立界面；
  * **settings 9/9 已出稿**（设置主页 / 机器人 / 端到端加密 / 通知 / 厂商保活 / 个人资料 /
    编辑资料 / 服务检测 / 免打扰）；
  * **office 5/7 已出稿**（Office 列表 / 文档 / 表格（新 `sheet` 版式）/ 演示 / 模板预览）；
    余下 2 个 `office_doc_page_frame`、`office_doc_paper` 是纸面与页眉页脚的绘制组件；
  * **零散模块 27 屏已出稿**：管理工具 / AI 服务 / AI 用量 / 使用分析 / 网络流量 /
    日历（新 `calendar` 版式）/ 联系人 / 编辑联系人 / 导入联系人 / 通讯录管理 /
    设计预览 / 诊断 / 登录 / 邮件列表 / 邮件详情 / 写信 / 内置播放器 /
    全局搜索 / 高级搜索 / 应用锁（新 `keypad` 版式）/ 证书 / NAS 管理 /
    连接 NAS / 工作台外壳 / 服务不可用 / 监控列表 / 单台摄像机；
  * 另有相册网格 1 屏作跨模块样例。
* 每屏 4 变体（暗/亮 × 中/英）＝ 616 张 SVG；总览页 `design/gen/index.html`。

### 非界面单元（不画稿，登记在此，避免"假装画过"）

| 单元 | 为什么不画 | 归属 |
|---|---|---|
| `photo_c2_sections.dart` | 只是 `photo_c2_page` 里的分组数据/文案表，没有独立界面 | 已并入 `photo_c2` 稿 |
| `sleep_backup_platform.dart` | 平台排程通道（MethodChannel 封装），无界面；界面在 `sleep_backup_page` | 已并入 `sleep_backup` 稿 |
| `drive_pdf_text_layer.dart` | 自研 PDF 的文字层/选区算法，无独立界面；界面在 `drive_pdf_markup_page` | 已并入 `drive_pdf_markup` 稿 |
| `note_body.dart` | 笔记正文的只读渲染组件（HTML→Delta→Quill），被 `note_view_page` 使用 | 已并入 `note_view` 稿 |
| `office_doc_page_frame.dart` | 页眉/页脚/页码的布局帧，无独立界面 | 已并入 `office_doc` 稿 |
| `office_doc_paper.dart` | 纸面绘制（纸张尺寸/缩放），无独立界面 | 已并入 `office_doc` 稿 |
| `drive_pdf_text_layer.dart` | 自研 PDF 的文字层联动（选区/复制），无独立界面 | 已并入 `drive_pdf` 稿 |
| `home_page.dart` | 应用外壳的首页容器，与 `app_shell_page.dart` 同屏 | 已并入 `app_shell` 稿 |
| `photo_c2_sections.dart` | 相册 C2 页内的分区组件 | 已并入 `photo_c2` 稿 |
| `sleep_backup_platform.dart` | 平台通道（睡眠/备份状态读取），无界面 | —（无界面可画） |
