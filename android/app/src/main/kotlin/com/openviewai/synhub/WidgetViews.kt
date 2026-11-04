package com.openviewai.synhub

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.text.format.DateUtils
import android.view.View
import android.widget.RemoteViews

/**
 * 4 个小组件共享的 RemoteViews 装配逻辑。
 *
 * ## 为什么缩略图用 `setImageViewBitmap` 而不是 `setImageViewUri`
 * `RemoteViews.setImageViewUri` 里放 `content://` URI 时，**加载发生在 launcher
 * 进程**——那个进程没有本 App FileProvider 的读权限，结果是格子一直空着
 * （而且是"看起来没报错"的那种空）。`setImageViewBitmap` 走 RemoteViews 自己的
 * 位图 Parcel 通道，跨进程可靠。代价是位图必须小：这里统一按
 * [MAX_THUMB_PX] 下采样（最近 4 张 × 320px，内存可忽略）。
 *
 * RemoteViews 有事务大小上限（~1MB，Android 12 起更严）：所以
 *   * ImageView 固定 4 个，不动态加；
 *   * 下采样后 JPEG/ARGB_8888 单张几十 KB，4 张远低于上限。
 */
internal object WidgetViews {

    /** 缩略图解码的最长边上限（像素）。 */
    const val MAX_THUMB_PX = 320

    /** 小组件里最多列几行（笔记 / 待办）。 */
    const val MAX_ROWS = 4

    /**
     * 小组件点击 → 显式 Intent 落到 [MainActivity]。
     *
     * `requestCode` 用 target 的哈希：不同 target 的 PendingIntent 必须区分，
     * 否则 `FLAG_UPDATE_CURRENT` 会让后一个把前一个覆盖掉（点哪张都开同一处）。
     */
    fun pendingIntent(context: Context, target: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = SynologyWidgetBridge.ACTION_OPEN
            putExtra(SynologyWidgetBridge.EXTRA_TARGET, target)
            // NEW_TASK：小组件点击时 App 可能完全没在运行
            // SINGLE_TOP：已经在跑就走 MainActivity.onNewIntent（不叠 Activity）
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getActivity(context, target.hashCode(), intent, flags)
    }

    /** 占位原因 → 人话（`values/strings.xml` 英文、`values-zh/` 中文）。 */
    fun placeholderString(context: Context, placeholder: WidgetPlaceholder): String =
        context.getString(
            when (placeholder) {
                WidgetPlaceholder.NOT_LOGGED_IN -> R.string.widget_placeholder_not_logged_in
                WidgetPlaceholder.NOT_CONNECTED -> R.string.widget_placeholder_not_connected
                WidgetPlaceholder.NO_PHOTOS -> R.string.widget_placeholder_no_photos
                WidgetPlaceholder.NO_NOTES -> R.string.widget_placeholder_no_notes
                WidgetPlaceholder.NO_TODOS -> R.string.widget_placeholder_no_todos
                WidgetPlaceholder.NO_NOTEBOOKS -> R.string.widget_placeholder_no_notebooks
            }
        )

    /**
     * 本地化的"多久以前 / 多久以后"（系统 `DateUtils`，跟随系统语言）。
     * `value <= 0`（服务端没给时间）返回空串，调用方据此隐藏那一行。
     */
    fun relativeTime(value: Long): CharSequence {
        if (value <= 0L) return ""
        return DateUtils.getRelativeTimeSpanString(
            value,
            System.currentTimeMillis(),
            DateUtils.MINUTE_IN_MILLIS,
            DateUtils.FORMAT_ABBREV_RELATIVE,
        )
    }

    /** 待办的截止时间文案（"截止 3 小时后" / "Due in 3 hours"）。 */
    fun dueText(context: Context, due: Long): String =
        context.getString(R.string.widget_due_prefix, relativeTime(due))

    /** 快照的"更新于…"，让用户知道这是不是旧数据。没有时间就空串。 */
    fun updatedText(context: Context, updatedAt: Long): String {
        val t = relativeTime(updatedAt)
        return if (t.isEmpty()) "" else context.getString(R.string.widget_updated_prefix, t)
    }

    /**
     * 本机缩略图 → 下采样后的位图。
     *
     * 任何情况（路径空 / 文件不存在 / 不是图片 / 内存不够）都返回 `null`，
     * 调用方改用占位图标 —— **绝不抛、绝不留白**。
     */
    fun decodeThumb(path: String?, maxPx: Int = MAX_THUMB_PX): Bitmap? {
        if (!WidgetSnapshotMapper.isThumbUsable(path)) return null
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            val w = bounds.outWidth
            val h = bounds.outHeight
            if (w <= 0 || h <= 0) return null
            var sample = 1
            while (w / (sample * 2) >= maxPx && h / (sample * 2) >= maxPx) {
                sample *= 2
            }
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            BitmapFactory.decodeFile(path, opts)
        } catch (t: Throwable) {
            // OutOfMemoryError 也是 Throwable：单张图失败不能拖垮整个小组件刷新
            null
        }
    }

    /**
     * ★ N1（110 轮）：把官方 **动作栏**（`appwidget_shortcut` 对应物）
     * 作为**嵌套 RemoteViews** 填进 [containerId]。
     *
     * 官方 6 格 → 落点（Dart 侧 `parseWidgetTarget` 解析）：
     *   logo → `notes`（只打开 App）/ camera → `note_camera` /
     *   audio → `note_audio` / attach → `note_att` /
     *   plain → `note_new` / todos → `todo_list`。
     *
     * 官方把这条动作栏**内嵌**在 `appwidget_notes` 与 `appwidget_todo` 里
     * （`<include layout="@layout/appwidget_shortcut" />`），
     * 所以笔记/待办/笔记列表三个列表组件也要调这个方法。
     */
    fun bindActionBar(context: Context, views: RemoteViews, containerId: Int) {
        val bar = RemoteViews(context.packageName, R.layout.widget_action_bar)
        bar.setOnClickPendingIntent(R.id.widget_action_logo, pendingIntent(context, "notes"))
        bar.setOnClickPendingIntent(
            R.id.widget_action_camera,
            pendingIntent(context, "note_camera"),
        )
        bar.setOnClickPendingIntent(
            R.id.widget_action_audio,
            pendingIntent(context, "note_audio"),
        )
        bar.setOnClickPendingIntent(
            R.id.widget_action_attach,
            pendingIntent(context, "note_att"),
        )
        bar.setOnClickPendingIntent(
            R.id.widget_action_note,
            pendingIntent(context, "note_new"),
        )
        bar.setOnClickPendingIntent(
            R.id.widget_action_todo,
            pendingIntent(context, "todo_list"),
        )
        views.removeAllViews(containerId)
        views.addView(containerId, bar)
    }

    /** 往 `@id/widget_rows` 里加一行（嵌套 RemoteViews，标准做法）。 */
    fun addRow(
        context: Context,
        views: RemoteViews,
        containerId: Int,
        title: String,
        subtitle: String,
        target: String,
    ) {
        val row = RemoteViews(context.packageName, R.layout.widget_row_layout)
        row.setTextViewText(R.id.widget_row_title, title)
        if (subtitle.isBlank()) {
            row.setViewVisibility(R.id.widget_row_subtitle, View.GONE)
        } else {
            row.setViewVisibility(R.id.widget_row_subtitle, View.VISIBLE)
            row.setTextViewText(R.id.widget_row_subtitle, subtitle)
        }
        row.setOnClickPendingIntent(R.id.widget_row_root, pendingIntent(context, target))
        views.addView(containerId, row)
    }

    /**
     * 标题 + "更新于…" + 占位文案的公共部分。
     *
     * ⚠️ **不在这里清空行容器**：列表类小组件（笔记/待办）的 `widget_rows` 是
     * XML 里留空的容器，重画前必须 `removeAllViews`（否则旧行会叠加）；而相册
     * 小组件的 `widget_photo_grid` 里是**静态写死的两行格子**，`removeAllViews`
     * 会把它们连同 4 个 ImageView 一起删掉（widget 变成空卡片）。
     * 所以清空是**列表 Provider 自己的责任**（见 `NotesWidgetProvider.build`）。
     *
     * @param contentContainerId 内容容器（相册是网格、笔记/待办是行容器）：
     *   占位时把它整体 `GONE`（不是留白，是收拢）。
     * @return `true` = 已经是"占位状态"，调用方直接 `return views`。
     */
    fun bindChrome(
        context: Context,
        views: RemoteViews,
        titleRes: Int,
        contentContainerId: Int,
        snapshot: WidgetSnapshot?,
        placeholder: WidgetPlaceholder?,
        placeholderTarget: String,
    ): Boolean {
        views.setTextViewText(R.id.widget_title, context.getString(titleRes))
        views.setOnClickPendingIntent(R.id.widget_title, pendingIntent(context, placeholderTarget))
        views.setOnClickPendingIntent(R.id.widget_root, pendingIntent(context, placeholderTarget))

        val updated = updatedText(context, snapshot?.updatedAt ?: 0L)
        if (updated.isEmpty()) {
            views.setViewVisibility(R.id.widget_updated, View.GONE)
        } else {
            views.setViewVisibility(R.id.widget_updated, View.VISIBLE)
            views.setTextViewText(R.id.widget_updated, updated)
        }

        if (placeholder != null) {
            views.setViewVisibility(R.id.widget_placeholder, View.VISIBLE)
            views.setTextViewText(R.id.widget_placeholder, placeholderString(context, placeholder))
            views.setViewVisibility(contentContainerId, View.GONE)
            return true
        }
        views.setViewVisibility(R.id.widget_placeholder, View.GONE)
        views.setViewVisibility(contentContainerId, View.VISIBLE)
        return false
    }
}
