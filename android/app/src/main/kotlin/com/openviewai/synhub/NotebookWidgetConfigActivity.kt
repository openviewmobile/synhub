package com.openviewai.synhub

import android.app.Activity
import android.app.AlertDialog
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import android.widget.Toast

/**
 * 笔记本小组件的**配置页** —— 官方对应物
 * `NotebookListAppWidgetActivity`（`appwidget_notebook.xml` 的
 * `android:configure` 指向它，第 109 轮取证）。
 *
 * 官方语义（**修正第 107 轮的错误假设**）：
 *   * 该组件的 label 是 `widget_notebook` = **"List of notes"（笔记列表）**，
 *     **不是**"笔记本列表"；用户先在配置页选一个笔记本，
 *     小组件里列的是**那个笔记本里的笔记**（布局 `appwidget_notes`
 *     里是 `@id/note_list` 的 ListView + 快捷栏 + 空态）。
 *   * 选"全部笔记"= 不过滤（我方额外给的一个选项，官方只有按本）。
 *
 * 选择按 **appWidgetId** 存进 SharedPreferences（同一小组件的多个实例
 * 可以选不同笔记本 —— 这是官方配置页存在的原因）。
 */
class NotebookWidgetConfigActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val manager = AppWidgetManager.getInstance(this)
        val widgetId = intent?.extras?.getInt(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID,
        ) ?: AppWidgetManager.INVALID_APPWIDGET_ID
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }
        val store = WidgetSnapshotStore(this)
        val snapshot = store.read()
        val books = snapshot?.notebooks ?: emptyList()
        val labels = ArrayList<String>()
        val ids = ArrayList<String>()
        labels.add(getString(R.string.widget_notebook_all))
        ids.add("")
        for (b in books) {
            labels.add(b.name.ifBlank { getString(R.string.widget_untitled_notebook) })
            ids.add(b.id)
        }
        val current = WidgetNotebookSelection.read(this, widgetId)
        val checked = ids.indexOf(current).coerceAtLeast(0)

        AlertDialog.Builder(this)
            .setTitle(R.string.widget_notebook_pick)
            .setSingleChoiceItems(labels.toTypedArray(), checked) { dialog, which ->
                WidgetNotebookSelection.write(this, widgetId, ids[which])
                dialog.dismiss()
                // 立刻重画（用户期望选完就变）
                NotebookWidgetProvider.refresh(this)
                val result = Intent().putExtra(
                    AppWidgetManager.EXTRA_APPWIDGET_ID,
                    widgetId,
                )
                setResult(RESULT_OK, result)
                finish()
            }
            .setOnCancelListener {
                // 取消 = 不放置该小组件（Android 约定：不 setResult(RESULT_OK)）
                setResult(RESULT_CANCELED)
                finish()
            }
            .show()
    }
}

/** 每个 widget 实例选了哪个笔记本（空串 = 全部笔记）。 */
object WidgetNotebookSelection {

    private const val PREFS = "synhub_widget_notebook"

    private fun key(widgetId: Int) = "widget_notebook_$widgetId"

    fun read(context: android.content.Context, widgetId: Int): String =
        try {
            context.applicationContext
                .getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)
                .getString(key(widgetId), "") ?: ""
        } catch (t: Throwable) {
            ""
        }

    fun write(context: android.content.Context, widgetId: Int, notebookId: String) {
        try {
            context.applicationContext
                .getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)
                .edit()
                .putString(key(widgetId), notebookId)
                .apply()
        } catch (t: Throwable) {
            // 存不下就当"全部笔记"（发个提示但绝不崩）
            Toast.makeText(context, R.string.widget_notebook_save_failed, Toast.LENGTH_SHORT)
                .show()
        }
    }
}
