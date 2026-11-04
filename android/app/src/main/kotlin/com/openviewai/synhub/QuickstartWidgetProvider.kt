package com.openviewai.synhub

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.widget.RemoteViews

/**
 * **「快捷启动」小组件** —— 官方 `ShortcutAppWidgetProvider` 的对应物
 * （label `widget_shortcut` = "Quickstart"，第 110 轮取证）。
 *
 * 官方布局 `res/layout/appwidget_shortcut.xml` 是 **6 格横向动作栏**：
 *
 * | 官方 id | 语义 | 我方落点 |
 * |---|---|---|
 * | `app` | App logo（只打开 App） | `notes` |
 * | `new_camera` | 从相机新建笔记 | `note_camera` |
 * | `new_audio` | 录音新建笔记 | `note_audio` |
 * | `new_att` | 加附件新建 | `note_att` |
 * | `new_plain` | 明文笔记 | `note_new` |
 * | `todos` | 待办列表 | `todo_list` |
 *
 * 这个组件**不依赖快照数据**（不读 `WidgetSnapshotStore`）：永远可用，
 * 未登录时点击由 App 的登录闸门接管（与点底栏 tab 一致）。
 */
class QuickstartWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        if (appWidgetIds.isEmpty()) return
        val views = build(context)
        for (id in appWidgetIds) appWidgetManager.updateAppWidget(id, views)
    }

    companion object {
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, QuickstartWidgetProvider::class.java)
            )
            if (ids.isEmpty()) return
            val views = build(context)
            for (id in ids) manager.updateAppWidget(id, views)
        }

        /** 根布局**就是**动作栏本身（与官方 `initialLayout=@layout/appwidget_shortcut` 一致）。 */
        fun build(context: Context): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_action_bar)
            WidgetViews.bindActionBar(context, views, R.id.widget_actions)
            return views
        }
    }
}
