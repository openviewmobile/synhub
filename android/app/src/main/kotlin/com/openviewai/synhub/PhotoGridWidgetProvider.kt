package com.openviewai.synhub

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.view.View
import android.widget.RemoteViews

/**
 * **相册小组件**（缺口 P66）：主屏 2×2 显示"最近 4 张照片"的缩略图。
 *
 * 数据来源：`SynologyWidgetBridge.pushSnapshot` 落盘的快照
 * （Dart 侧 `recentWidgetPhotos` **纯函数**取最近 N 张并排序/去重，见
 * `lib/src/features/widgets/widget_snapshot.dart`）。
 *
 * 刷新路径：
 *   * **主动**：App 数据变化 → pushSnapshot → `updateAppWidget`（本类的
 *     [refresh]）；
 *   * **被动**：`res/xml/widget_photos_info.xml` 的 `updatePeriodMillis`
 *     （30 分钟）由系统唤醒 [onUpdate]。
 *
 * 无数据 / 未登录 / 未连接 → 显示**人话占位**（[WidgetViews.bindChrome]）；
 * 单张缩略图缺失 → 该格子画占位图标（**不留白、不崩**）。
 */
class PhotoGridWidgetProvider : AppWidgetProvider() {

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
        /** 4 个格子，顺序与 `widget_photos_layout.xml` 里的 id 一致。 */
        private val TILE_IDS = intArrayOf(
            R.id.widget_photo_0,
            R.id.widget_photo_1,
            R.id.widget_photo_2,
            R.id.widget_photo_3,
        )

        /** 重画所有已放置的相册小组件（由 `SynologyWidgetBridge` 调用）。 */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, PhotoGridWidgetProvider::class.java)
            )
            if (ids.isEmpty()) return
            val views = build(context)
            for (id in ids) manager.updateAppWidget(id, views)
        }

        /** 组装本次要画的 RemoteViews（纯装配，无副作用）。 */
        fun build(context: Context): RemoteViews {
            val snapshot = WidgetSnapshotStore(context).read()
            val views = RemoteViews(context.packageName, R.layout.widget_photos_layout)

            val placeholder = WidgetSnapshotMapper.placeholder(snapshot, WidgetKind.PHOTOS)
            if (WidgetViews.bindChrome(
                    context,
                    views,
                    R.string.widget_photos_label,
                    R.id.widget_photo_grid,
                    snapshot,
                    placeholder,
                    "photos",
                )
            ) {
                return views
            }

            // 快照里的 photos 已经由 Dart 纯函数排好序；这里只兜底截断
            val photos = snapshot!!.photos.take(TILE_IDS.size)
            for (i in TILE_IDS.indices) {
                val tile = TILE_IDS[i]
                val photo = photos.getOrNull(i)
                if (photo == null) {
                    // 不足 4 张：多出来的格子直接隐藏（不是空白，是布局收拢）
                    views.setViewVisibility(tile, View.GONE)
                    continue
                }
                views.setViewVisibility(tile, View.VISIBLE)
                val bitmap = WidgetViews.decodeThumb(photo.thumbPath)
                if (bitmap != null) {
                    views.setImageViewBitmap(tile, bitmap)
                } else {
                    views.setImageViewResource(tile, R.drawable.ic_widget_placeholder)
                }
                views.setOnClickPendingIntent(
                    tile,
                    WidgetViews.pendingIntent(context, "photo:${photo.id}"),
                )
            }
            return views
        }
    }
}
