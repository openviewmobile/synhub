package com.openviewai.synhub

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * 主屏小组件（P66 相册 / N1 笔记）的**快照落盘 + 纯映射**。
 *
 * ## 为什么小组件不自己连 NAS
 * `AppWidgetProvider` 跑在 **launcher 进程**里：没有登录会话（`_sid`），也没有
 * 自签证书信任链与 Dio 客户端。让小组件直连 NAS 等于在 Kotlin 里重写一遍鉴权 +
 * 证书逻辑，而且刷新失败就只剩空白。所以数据流是：
 *
 * ```
 * Flutter App 运行时
 *   → WidgetSnapshotPublisher（lib/src/features/widgets/widget_snapshot_publisher.dart）
 *   → encodeWidgetSnapshot(...)（纯函数，lib/src/features/widgets/widget_snapshot.dart）
 *   → MethodChannel "synhub/widget".pushSnapshot(json)
 *   → WidgetSnapshotStore.save()（本文件，SharedPreferences）
 *   → AppWidgetManager.updateAppWidget(...)（立刻重画）
 * ```
 *
 * ## 与 Dart 侧的契约（**必须逐字同步**）
 * JSON schema 由 Dart 侧 `widget_snapshot.dart` 定义，版本号 [VERSION]；
 * [parse] 只认这个版本，不认识的整份丢弃（宁可不显示，也不显示错字段）。
 *
 * [Placeholder] 枚举与 Dart 侧 `WidgetPlaceholder` 一一对应，顺序也一致；
 * 占位判定顺序（未登录 → 未连接 → 空数据）是**行为契约**：未登录时说
 * "连不上 NAS"会把用户骗去查网络。
 */
class WidgetSnapshotStore(context: Context) {

    private val prefs =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** 落盘一份快照。**任何异常都吞成 false**（小组件不该让 App 挂掉）。 */
    fun save(json: String?): Boolean {
        if (json.isNullOrBlank()) return false
        // 先校验一遍：写进去一份自己都解析不了的快照，等于让小组件显示占位，
        // 还不如报 false 让 Dart 侧知道"没落盘成功"（照旧不报错）。
        if (parse(json) == null) return false
        return try {
            prefs.edit().putString(KEY_SNAPSHOT, json).apply()
            true
        } catch (t: Throwable) {
            Log.w(TAG, "小组件快照落盘失败", t)
            false
        }
    }

    /** 读回落盘的快照；没有 / 坏了 / 版本不认识 → `null`。 */
    fun read(): WidgetSnapshot? = try {
        parse(prefs.getString(KEY_SNAPSHOT, null))
    } catch (t: Throwable) {
        Log.w(TAG, "小组件快照读取失败", t)
        null
    }

    companion object {
        private const val TAG = "SynoWidget"
        private const val PREFS = "synhub_widget"
        private const val KEY_SNAPSHOT = "snapshot_json"

        /** 与 `widget_snapshot.dart` 的 `kWidgetSnapshotVersion` 逐字相同。 */
        const val VERSION = 1

        /**
         * JSON → [WidgetSnapshot]。**绝不抛**：
         * 空串 / 半截 JSON / 类型不对 / 版本不认识，一律 `null`。
         */
        fun parse(json: String?): WidgetSnapshot? {
            if (json.isNullOrBlank()) return null
            return try {
                val root = JSONObject(json)
                if (root.optInt("v", 0) != VERSION) return null
                WidgetSnapshot(
                    loggedIn = root.optBoolean("loggedIn", false),
                    connected = root.optBoolean("connected", false),
                    updatedAt = root.optLong("updatedAt", 0L),
                    photos = readList(root.optJSONArray("photos")) { o ->
                        WidgetPhoto(
                            id = o.optString("id", ""),
                            name = o.optString("name", ""),
                            takenAt = o.optLong("takenAt", 0L),
                            thumbPath = o.optString("thumbPath", "").ifBlank { null },
                            video = o.optBoolean("video", false),
                        )
                    },
                    notes = readList(root.optJSONArray("notes")) { o ->
                        WidgetNote(
                            id = o.optString("id", ""),
                            title = o.optString("title", ""),
                            mtime = o.optLong("mtime", 0L),
                            encrypted = o.optBoolean("encrypted", false),
                            // ★ 109 轮：官方 Notebook widget 按本过滤
                            notebookId = o.optString("notebookId", ""),
                            notebookName = o.optString("notebookName", ""),
                        )
                    },
                    todos = readList(root.optJSONArray("todos")) { o ->
                        WidgetTodo(
                            id = o.optString("id", ""),
                            noteId = o.optString("noteId", ""),
                            title = o.optString("title", ""),
                            due = o.optLong("due", 0L),
                            done = o.optBoolean("done", false),
                        )
                    },
                    // ★ N1（107 轮）：笔记本小组件。旧快照没有这个键 ⇒ 空列表，
                    //   于是笔记本小组件显示"还没有笔记本"占位（不会崩）。
                    notebooks = readList(root.optJSONArray("notebooks")) { o ->
                        WidgetNotebook(
                            id = o.optString("id", ""),
                            name = o.optString("name", ""),
                            count = o.optInt("count", 0),
                            mtime = o.optLong("mtime", 0L),
                        )
                    },
                )
            } catch (t: Throwable) {
                // JSONException / 递归过深 / 其它：一律当"没有快照"
                Log.w(TAG, "小组件快照解析失败", t)
                null
            }
        }

        private fun <T> readList(
            array: JSONArray?,
            map: (JSONObject) -> T,
        ): List<T> {
            if (array == null) return emptyList()
            val out = ArrayList<T>(array.length())
            for (i in 0 until array.length()) {
                val o = array.optJSONObject(i) ?: continue // 单条脏数据丢弃，不影响其余
                try {
                    out.add(map(o))
                } catch (t: Throwable) {
                    Log.w(TAG, "小组件快照单条解析失败，已跳过", t)
                }
            }
            return out
        }
    }
}

/** 相册小组件里的一张照片（`thumbPath` 是 App 落到本机的缩略图绝对路径）。 */
data class WidgetPhoto(
    val id: String,
    val name: String,
    val takenAt: Long,
    val thumbPath: String?,
    val video: Boolean,
)

/** 笔记小组件里的一条笔记（**只有标题**，绝不带正文）。 */
data class WidgetNote(
    val id: String,
    val title: String,
    val mtime: Long,
    val encrypted: Boolean,
    val notebookId: String = "",
    val notebookName: String = "",
)

/** 笔记本小组件里的一个笔记本（官方 `NotebookAppWidgetProvider` 对应物）。 */
data class WidgetNotebook(
    val id: String,
    val name: String,
    val count: Int,
    val mtime: Long,
)

/** 待办小组件里的一条待办。 */
data class WidgetTodo(
    val id: String,
    val noteId: String,
    val title: String,
    val due: Long,
    val done: Boolean,
)

/** 一份快照。 */
data class WidgetSnapshot(
    val loggedIn: Boolean,
    val connected: Boolean,
    val updatedAt: Long,
    val photos: List<WidgetPhoto>,
    val notes: List<WidgetNote>,
    val todos: List<WidgetTodo>,
    val notebooks: List<WidgetNotebook> = emptyList(),
)

/** 小组件类别（决定"空数据"时说哪句人话）。 */
enum class WidgetKind { PHOTOS, NOTES, TODOS, NOTEBOOKS }

/**
 * 快照为什么画不出内容。`null`（见 [WidgetSnapshotMapper.placeholder]）= 能画。
 *
 * ⚠️ 与 Dart 侧 `WidgetPlaceholder` **一一对应**，同步改动。
 */
enum class WidgetPlaceholder {
    NOT_LOGGED_IN,
    NOT_CONNECTED,
    NO_PHOTOS,
    NO_NOTES,
    NO_TODOS,
    NO_NOTEBOOKS,
}

/**
 * 纯映射（无 Android API、可单测的思路与 Dart 侧一致）：
 * 快照 + 类别 → "要不要显示占位、显示哪一种"。
 */
object WidgetSnapshotMapper {

    /**
     * 相册/笔记/待办小组件能不能画出内容；`null` = **能**。
     *
     * 顺序（先登录、再连接、最后空数据）是行为契约，见类头注释。
     */
    fun placeholder(snapshot: WidgetSnapshot?, kind: WidgetKind): WidgetPlaceholder? {
        if (snapshot == null || !snapshot.loggedIn) return WidgetPlaceholder.NOT_LOGGED_IN
        if (!snapshot.connected) return WidgetPlaceholder.NOT_CONNECTED
        return when (kind) {
            WidgetKind.PHOTOS ->
                if (snapshot.photos.isEmpty()) WidgetPlaceholder.NO_PHOTOS else null
            WidgetKind.NOTES ->
                if (snapshot.notes.isEmpty()) WidgetPlaceholder.NO_NOTES else null
            WidgetKind.TODOS ->
                // 待办为空是常态（今天没事做），这句是正常空态、不是错误
                if (snapshot.todos.isEmpty()) WidgetPlaceholder.NO_TODOS else null
            WidgetKind.NOTEBOOKS ->
                if (snapshot.notebooks.isEmpty()) WidgetPlaceholder.NO_NOTEBOOKS else null
        }
    }

    /**
     * 单张照片格子能不能画：`thumbPath` 非空**且文件存在可读**。
     *
     * 单独抽出来是因为它同时被"画格子"和"决定要不要用占位图标"两处需要，
     * 而且判的是**文件系统**（App 可能刚被清理过缓存）。
     */
    fun isThumbUsable(path: String?): Boolean {
        if (path.isNullOrBlank()) return false
        return try {
            val f = java.io.File(path)
            f.isFile && f.canRead() && f.length() > 0L
        } catch (t: Throwable) {
            false
        }
    }
}
