# 七个**非页面**单元（160 个界面单元的诚实分类）

> 为什么单列：`inventory.json` 的 160 个"界面单元"是按**文件**数的，其中 7 个并不是独立屏幕 ——
> 它们是别名、数据模型、绘制内部件或平台抽象。给它们硬套一张"页面稿"只会造出假稿
> （r564 之前那 153 张占位板就是这么来的）。这份表逐条说清**它是什么**、**在哪张真稿里看得见**。
>
> 守卫：`test/design_gallery_fidelity_test.dart` ②（占位板只能出现在这 7 个上）
> ＋ 本表每行必须给出 ≥20 字的说明与一个**存在的**引用 spec。

| 单元文件 | 类别 | 它是什么 | 在哪张真稿里看得见 |
|---|---|---|---|
| `lib/src/features/home/home_page.dart` | 别名 | 只有 3 行的转发：`build() => const AppShellPage()`；登录后落到外壳，没有自己的界面 | `app_shell`（应用外壳） |
| `lib/src/features/drive/drive_pdf_text_layer.dart` | 数据模型 | PDF 文本层：把一页文字解成"归一化框 + 文本"，供搜索/选词/批注命中；不画任何像素 | `drive_pdf_markup`（PDF 批注页里选中的文字） |
| `lib/src/features/notes/note_body.dart` | 绘制部件 | 笔记正文的排版件（标题/段落/待办/引用/代码），被编辑页与阅读页共用；它的配色与字号**全部来自令牌**，不单独出屏 | `note_editor`（笔记编辑页正文区） |
| `lib/src/features/office/office_doc_page_frame.dart` | 绘制部件 | 文档页的外框（描边、投影、页间距），由画布在滚动时反复调用 | `office_doc`（文档页视图） |
| `lib/src/features/office/office_doc_paper.dart` | 绘制部件 | 纸张本身（纸色、页边距、页眉页脚线、页码位置） | `office_doc`（文档页视图） |
| `lib/src/features/photos/photo_c2_sections.dart` | 绘制部件 | 条件相册子页的共用外壳与分区（`PhotoC2Scaffold`、地图/人物/条件行），多个子页共用 | `photo_c2`（条件相册） |
| `lib/src/features/files/djvu_archive.dart` | 数据层 | DJVU（.djvu）**容器层**：IFF/FORM 分块、INFO、文本层（TXTz/TXTa）、注释、书签、多页目录 —— 纯 Dart，零 flutter/l10n 依赖，不画像素（★ r591：它的旧 spec 画的是一张「DJVU 暂不支持」的提示屏，而 `book_djvu.dart` 早已支持 DJVU ⇒ 那张稿已删） | 无（纯 Dart 容器层；DJVU 页与「不支持的格式」原因行由 `file_book_view.dart` 的阅读器渲染，该页无独立 spec） |
| `lib/src/core/platform/sleep_backup_platform.dart` | 平台抽象 | 睡眠备份的平台通道封装（定时/唤醒/文件枚举），**没有任何界面** | 无（纯服务层；设置项在 `sleep_backup`） |
