# 半透明 primary 底：逐处裁定（`DA186` 的系统守卫清单）

> 为什么有这份清单：`primary` 文字压在 `primary@α` 的**半透明**底上，透出页面底后
> 合成对比度会掉到 **4.2–4.5:1**（真机亮色实测），这是同一类缺陷第 1–5 次出现
> （`DA176` 相册分段 · `DA183` 文件来源 · `DA185` Drive 四段 · `DA186` 通讯录/笔记/流量/
> Drive 搜索/下载/表情胶囊）。**文字底一律用不透明的 `primarySoft`**（5.00:1）。
>
> 守卫：`test/translucent_primary_text_guard_test.dart`。新增一处半透明 primary 底，
> 必须在这里登记并说明"它上面叠的不是 primary 文字 / 判据是图标 3:1"。

## 已裁定为"非文字底"（允许保留）

- `lib/src/core/theme/app_theme.dart` @0.08 — 主题级非文字色（高亮/指示条/进度轨道/滑块光晕）——不与文字叠字
- `lib/src/core/theme/app_theme.dart` @0.12 — 主题级非文字色（高亮/指示条/进度轨道/滑块光晕）——不与文字叠字
- `lib/src/core/theme/app_theme.dart` @0.16 — 主题级非文字色（高亮/指示条/进度轨道/滑块光晕）——不与文字叠字
- `lib/src/core/theme/app_tokens.dart` @0.05 — 渐变/网格/暗角等装饰层——不与文字叠字
- `lib/src/core/theme/app_tokens.dart` @0.10 — 渐变/网格/暗角等装饰层——不与文字叠字
- `lib/src/core/theme/app_tokens.dart` @0.14 — 渐变/网格/暗角等装饰层——不与文字叠字
- `lib/src/core/ui/app_sheet.dart` @0.18 — 圆形动作钮的**图标**底（图标判据 3:1，实测 4.4:1 达标）
- `lib/src/core/ui/app_states.dart` @0.08 — 空态圆形图标章（图标 3:1）
- `lib/src/core/ui/app_states.dart` @0.18 — 空态圆形图标章（图标 3:1）
- `lib/src/core/ui/glass_text_field.dart` @0.10 — 输入框聚焦时的**填充**，上面的字是 onSurface（不是 primary）
- `lib/src/features/calendar/calendar_page.dart` @0.10 — 周视图选中**整列**的底色/日期格底色——上面的文字不是 primary
- `lib/src/features/calendar/calendar_page.dart` @0.18 — 周视图选中**整列**的底色/日期格底色——上面的文字不是 primary
- `lib/src/features/chat/chat_page.dart` @0.10 — 图标底（3:1）与 mini 头像描边；文字版胶囊已改 primarySoft
- `lib/src/features/contacts/contact_detail_sheet.dart` @0.18 — 头像首字圆（大字 bold ⇒ 判据 3:1）
- `lib/src/features/contacts/contact_editor_page.dart` @0.18 — 头像首字圆（大字 bold ⇒ 判据 3:1）
- `lib/src/features/design/design_preview_page.dart` @0.10 — 设计预览器内部的示例块（不是产品界面）
- `lib/src/features/design/design_preview_page.dart` @0.18 — 设计预览器内部的示例块（不是产品界面）
- `lib/src/features/files/file_browse_page.dart` @0.18 — **注释**里引用了旧写法（`DA183` 的说明），不是实际绘制
- `lib/src/features/files/file_row.dart` @0.10 — 网格选中行底色，文字不是 primary；勾选图标 3:1
- `lib/src/features/notes/note_widgets.dart` @0.12 — 行选中底色（文字不是 primary）
- `lib/src/features/office/office_slides_deck_view.dart` @0.16 — 缩略图选中框底色；页码文字不是 primary
- `lib/src/features/shell/app_shell_page.dart` @0.14 — 启动器图标位（图标 3:1）
