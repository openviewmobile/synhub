package com.openviewai.synhub

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.widget.RemoteViews

/**
 * **「新建笔记」快捷小组件**（缺口 N1 的 Shortcut 部分）。
 *
 * 这个组件**不依赖任何数据**（不读快照、不需要登录），所以它永远可用：
 * 一个小方块，点一下 → 打开 App 的笔记 tab 并直接进入新建编辑器
 * （落点 `note_new`）。
 *
 * 未登录时点击仍然按落点走：`WidgetSnapshotHost` 会切到笔记 tab，
 * **登录闸门**（`ServiceGatePages` / 登录页）会照常接管 —— 这与点底栏
 * "笔记" tab 的行为完全一致，不特判、不假装能新建。
 */
class NewNoteWidgetProvider : AppWidgetProvider() {

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
                ComponentName(context, NewNoteWidgetProvider::class.java)
            )
            if (ids.isEmpty()) return
            val views = build(context)
            for (id in ids) manager.updateAppWidget(id, views)
        }

        fun build(context: Context): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_shortcut_layout)
            val label = context.getString(R.string.widget_new_note_label)
            views.setTextViewText(R.id.widget_shortcut_label, label)
            views.setTextViewText(
                R.id.widget_shortcut_hint,
                context.getString(R.string.widget_new_note_hint),
            )
            val intent = WidgetViews.pendingIntent(context, "note_new")
            views.setOnClickPendingIntent(R.id.widget_root, intent)
            views.setOnClickPendingIntent(R.id.widget_shortcut_icon, intent)
            views.setOnClickPendingIntent(R.id.widget_shortcut_label, intent)
            return views
        }
    }
}
