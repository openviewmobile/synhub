package com.openviewai.synhub

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.widget.RemoteViews

/**
 * **待办小组件**（缺口 N1 的 Todo 部分）：主屏列出"最紧急的 4 条未完成待办"。
 *
 * 排序与过滤（有截止时间的在前、`due` 升序、已完成滤掉）由 Dart 侧纯函数
 * `widgetPendingTodos` 完成；这里**再兜底过滤一次** `done`，防止旧版本 App
 * 写下的快照把已完成的待办画出来。
 *
 * 点击某一行 → 打开 App 的笔记 tab 并进入该待办所属的笔记
 * （落点 `todo:<noteId>`）。
 */
class TodosWidgetProvider : AppWidgetProvider() {

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
                ComponentName(context, TodosWidgetProvider::class.java)
            )
            if (ids.isEmpty()) return
            val views = build(context)
            for (id in ids) manager.updateAppWidget(id, views)
        }

        fun build(context: Context): RemoteViews {
            val snapshot = WidgetSnapshotStore(context).read()
            val views = RemoteViews(context.packageName, R.layout.widget_list_layout)

            val placeholder = WidgetSnapshotMapper.placeholder(snapshot, WidgetKind.TODOS)
            if (WidgetViews.bindChrome(
                    context,
                    views,
                    R.string.widget_todos_label,
                    R.id.widget_rows,
                    snapshot,
                    placeholder,
                    "notes",
                )
            ) {
                return views
            }

            val todos = snapshot!!.todos
                .filter { !it.done }
                .take(WidgetViews.MAX_ROWS)
            // ★ N1（110 轮）：官方把动作栏**内嵌**在列表组件里
            //   （`appwidget_notes`/`appwidget_todo` 的 <include>）
            WidgetViews.bindActionBar(context, views, R.id.widget_actions_holder)
            // ⚠️ 必须自己清空（理由同 NotesWidgetProvider）
            views.removeAllViews(R.id.widget_rows)
            for (todo in todos) {
                val title = todo.title.ifBlank { context.getString(R.string.widget_untitled_todo) }
                val subtitle = if (todo.due > 0L) WidgetViews.dueText(context, todo.due) else ""
                // 待办点进去是它所属的那条笔记；noteId 为空时退到"笔记 tab"
                val target = if (todo.noteId.isNotBlank()) "todo:${todo.noteId}" else "notes"
                WidgetViews.addRow(
                    context,
                    views,
                    R.id.widget_rows,
                    title,
                    subtitle,
                    target,
                )
            }
            return views
        }
    }
}
