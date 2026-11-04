package com.openviewai.synhub

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.widget.RemoteViews

/**
 * **笔记本小组件**（缺口 N1 的最后一块）：主屏列出"最近使用的 4 个笔记本"。
 *
 * ★★★ **第 109 轮语义更正**（推翻第 107 轮的假设）：
 * 官方 `NotebookAppWidgetProvider` 的 label 是 `widget_notebook` =
 * **"List of notes"**，布局 `appwidget_notes` 里是 `@id/note_list` 的
 * **笔记** ListView，并且带**配置页**
 * （`appwidget_notebook.xml` → `android:configure=NotebookListAppWidgetActivity`）
 * —— 用户先选一个笔记本，组件列的是**那个笔记本里的笔记**。
 * 第 107 轮把它做成了"笔记本列表"，**语义错了**，本轮按官方改正。
 *
 * 官方还有 `widget_note_passcode_locked` 的"应用锁开启时不显示笔记"空态；
 * 我方尚未接应用锁与小组件的联动（诚实登记在案）。
 *
 * 排序（`mtime` 降序、同时间按 id 升序）由 Dart 侧纯函数 `widgetNotebooks`
 * 完成 —— 这里**不再重排**，保证两端一致（Kotlin 只负责画）。
 *
 * 点击某一行 → 打开 App 的笔记 tab（落点 `notebook:<objectId>`；
 * 逐本聚焦需要笔记页支持外部指定笔记本，本批不做假承诺）。
 */
class NotebookWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, build(context, id))
        }
    }

    companion object {
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, NotebookWidgetProvider::class.java)
            )
            // 每个实例可能选了不同笔记本 ⇒ **逐实例**构建
            for (id in ids) manager.updateAppWidget(id, build(context, id))
        }

        fun build(context: Context, widgetId: Int): RemoteViews {
            val snapshot = WidgetSnapshotStore(context).read()
            val views = RemoteViews(context.packageName, R.layout.widget_list_layout)

            // ★ 109 轮：按**本实例选中的笔记本**过滤（空串 = 全部笔记）
            val selected = WidgetNotebookSelection.read(context, widgetId)
            val scoped = (snapshot?.notes ?: emptyList())
                .filter { selected.isBlank() || it.notebookId == selected }
            // 占位判定必须基于**过滤后**的集合：选了空笔记本时要说
            // "还没有笔记"，而不是去数笔记本数量（第 107 轮就是数错了对象）
            val placeholder = when {
                snapshot == null || !snapshot.loggedIn ->
                    WidgetPlaceholder.NOT_LOGGED_IN
                !snapshot.connected -> WidgetPlaceholder.NOT_CONNECTED
                scoped.isEmpty() -> WidgetPlaceholder.NO_NOTES
                else -> null
            }
            if (WidgetViews.bindChrome(
                    context,
                    views,
                    R.string.widget_notebooks_label,
                    R.id.widget_rows,
                    snapshot,
                    placeholder,
                    "notes",
                )
            ) {
                return views
            }

            val notes = scoped.take(WidgetViews.MAX_ROWS)
            // ★ N1（110 轮）：官方把动作栏**内嵌**在列表组件里
            //   （`appwidget_notes`/`appwidget_todo` 的 <include>）
            WidgetViews.bindActionBar(context, views, R.id.widget_actions_holder)
            // ⚠️ 必须自己清空（理由同 NotesWidgetProvider：行容器是嵌套
            //    RemoteViews，不清空会叠加上一次的行）
            views.removeAllViews(R.id.widget_rows)
            for (note in notes) {
                val title = note.title.ifBlank {
                    context.getString(R.string.widget_untitled_note)
                }
                val subtitle = if (note.encrypted) {
                    context.getString(R.string.widget_encrypted_marker)
                } else {
                    // 全部笔记模式下用笔记本名当副标题（官方按本模式下不显示）
                    if (selected.isBlank()) note.notebookName else ""
                }
                WidgetViews.addRow(
                    context,
                    views,
                    R.id.widget_rows,
                    title,
                    subtitle,
                    "note:${note.id}",
                )
            }
            return views
        }
    }
}
