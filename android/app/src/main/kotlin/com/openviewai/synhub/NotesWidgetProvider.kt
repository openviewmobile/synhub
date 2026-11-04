package com.openviewai.synhub

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.view.View
import android.widget.RemoteViews

/**
 * **笔记小组件**（缺口 N1 的 Notebook 部分）：主屏列出"最近 4 条笔记"。
 *
 * ⚠️ 快照里**只有标题，没有正文**（Dart 侧 `widgetNoteEntryOf` 就只带标题）：
 *   * 加密笔记在服务端是密文，小组件进程也没有解密密钥；
 *   * 主屏是"别人一眼能看见"的地方，带正文等于泄露。
 * 加密笔记用 `🔒 已加密` 标注（`widget_encrypted_marker`）。
 *
 * 点击某一行 → 打开 App 的笔记 tab 并进入那条笔记
 * （落点 `note:<objectId>`，见 `WidgetSnapshotHost._route`）。
 */
class NotesWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        if (appWidgetIds.isEmpty()) return
        val views = build(context)
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    companion object {
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, NotesWidgetProvider::class.java)
            )
            if (ids.isEmpty()) return
            val views = build(context)
            for (id in ids) manager.updateAppWidget(id, views)
        }

        fun build(context: Context): RemoteViews {
            val snapshot = WidgetSnapshotStore(context).read()
            val views = RemoteViews(context.packageName, R.layout.widget_list_layout)

            val placeholder = WidgetSnapshotMapper.placeholder(snapshot, WidgetKind.NOTES)
            if (WidgetViews.bindChrome(
                    context,
                    views,
                    R.string.widget_notes_label,
                    R.id.widget_rows,
                    snapshot,
                    placeholder,
                    "notes",
                )
            ) {
                return views
            }

            val marker = context.getString(R.string.widget_encrypted_marker)
            val notes = snapshot!!.notes.take(WidgetViews.MAX_ROWS)
            // ★ N1（110 轮）：官方把动作栏**内嵌**在列表组件里
            //   （`appwidget_notes`/`appwidget_todo` 的 <include>）
            WidgetViews.bindActionBar(context, views, R.id.widget_actions_holder)
            // ⚠️ 必须自己清空：RemoteViews 是"增量命令"集合，不清会把上一次的行叠加
            views.removeAllViews(R.id.widget_rows)
            for (note in notes) {
                val title = note.title.ifBlank { context.getString(R.string.widget_untitled_note) }
                val time = WidgetViews.relativeTime(note.mtime).toString()
                val subtitle = when {
                    note.encrypted && time.isNotBlank() -> "$marker · $time"
                    note.encrypted -> marker
                    else -> time
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
