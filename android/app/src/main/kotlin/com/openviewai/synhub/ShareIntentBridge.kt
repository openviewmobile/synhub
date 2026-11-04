// 「分享到 Chat」的入站通道（对齐原版 exported `ShareActivity`）。
//
// 原版在 `AndroidManifest.xml:224-241` 注册了一个 exported 的
// `com.synology.dschat.ui.activity.ShareActivity`，收 `ACTION_SEND` /
// `ACTION_SEND_MULTIPLE`（`*/*`），由 `ShareEditFragment.handleIntent` 读
// `EXTRA_TEXT` / `EXTRA_SUBJECT` / `EXTRA_STREAM`，超过 50 个附件直接砍掉并提示
// （`error_share_exceed_max_files`），选频道后上传。
//
// 我们不在原生里做 UI：原生只负责**把入站 intent 变成 Dart 能吃的载荷**
// （content:// 复制到 cacheDir 得到真实路径、取显示名与 MIME），UI/发送全在
// Dart（`lib/src/features/chat/share_intent*.dart`）。
//
// 与 Dart 的接口（MethodChannel `synhub/share_intent`）：
//   调用方向 Dart→原生：getPending（取走并清空待处理分享，无则 null）
//   回调方向 原生→Dart：onShare（**无载荷**的"有新分享"提醒；Dart 收到后
//                       再 getPending。这样冷启动/热启动只有一条消费路径，
//                       不会重复处理）
package com.openviewai.synhub

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

object ShareIntentBridge {
    const val CHANNEL = "synhub/share_intent"
    private const val TAG = "SynologyChatShare"

    /** 原版 `ShareEditFragment.MAX_UPLOAD_COUNT = 50`（多出来的砍掉并提示）。 */
    private const val MAX_FILES = 50

    /** 复制入站文件到 `cacheDir/share_in/`。 */
    private const val DIR = "share_in"

    /** 标记"这个 Intent 已经处理过"，避免 Activity 重建时重复解析。 */
    private const val EXTRA_HANDLED = "com.openviewai.synhub.SHARE_HANDLED"

    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private val io = Executors.newSingleThreadExecutor()

    @Volatile private var pending: Map<String, Any?>? = null

    fun attach(context: Context, engine: FlutterEngine) {
        appContext = context.applicationContext
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "getPending" -> {
                    val p = pending
                    pending = null
                    result.success(p)
                }
                else -> result.notImplemented()
            }
        }
        // 冷启动：`configureFlutterEngine` 就在 `MainActivity.onCreate` 里，这里主动看一次
        // 启动 Intent，避免"先 attach 后 onCreate 调 handleIntent"的顺序问题。
        (context as? Activity)?.let { handleIntent(it.intent) }
    }

    /**
     * `MainActivity.onCreate` / `onNewIntent` 里调用。
     *
     * 不是分享 intent 就立刻返回；解析与文件复制放到后台线程，完成后存 pending
     * 并 `onShare` 提醒 Dart 来取（复制几十 MB 的视频不能卡主线程）。
     */
    fun handleIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) {
            return
        }
        if (intent.getBooleanExtra(EXTRA_HANDLED, false)) return
        intent.putExtra(EXTRA_HANDLED, true)
        val ctx = appContext ?: return
        io.execute {
            val payload = try {
                parse(ctx, intent)
            } catch (e: Exception) {
                Log.w(TAG, "解析分享 intent 失败", e)
                null
            }
            if (payload == null) return@execute
            pending = payload
            val ch = channel ?: return@execute
            Handler(Looper.getMainLooper()).post {
                ch.invokeMethod("onShare", null)
            }
        }
    }

    private fun parse(ctx: Context, intent: Intent): Map<String, Any?>? {
        val action = intent.action ?: return null
        val type = intent.type ?: ""
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT) ?: ""
        val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: ""

        val uris = ArrayList<Uri>()
        when (action) {
            // 单文件（也可能只有文本）：EXTRA_STREAM 是单个 Uri
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                val one = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (one != null) {
                    uris.add(one)
                } else {
                    // 历史兼容：少数发送方即使 ACTION_SEND 也塞 ArrayList
                    @Suppress("DEPRECATION")
                    val many = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                    if (many != null) uris.addAll(many)
                }
            }
            // 多文件：EXTRA_STREAM 是 ArrayList<Uri>。
            // 必须**全部**收下（"只取第一个"是 bug：多选图片分享过去会丢图）。
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                val many = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                if (many != null) {
                    uris.addAll(many)
                } else {
                    // 单个 Uri 也兼容一下（个别发送方 action 写成 MULTIPLE 却只给一个）
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
                }
            }
        }

        var overflow = 0
        if (uris.size > MAX_FILES) {
            overflow = uris.size - MAX_FILES
            Log.i(TAG, "分享附件 ${uris.size} 个，超过 $MAX_FILES，丢弃 $overflow 个")
        }

        val files = ArrayList<Map<String, Any?>>()
        for (uri in uris.take(MAX_FILES)) {
            copyToCache(ctx, uri)?.let { files.add(it) }
        }

        // 既没有文件也没有文本 → 没什么可分享的
        if (files.isEmpty() && text.isBlank()) return null

        return mapOf(
            "action" to action,
            "mime_type" to type,
            "text" to text,
            "subject" to subject,
            "files" to files,
            "overflow" to overflow,
        )
    }

    /** `content://` / `file://` → `cacheDir/share_in/<时间戳>_<显示名>`。 */
    private fun copyToCache(ctx: Context, uri: Uri): Map<String, Any?>? {
        return try {
            val name = displayName(ctx, uri) ?: "shared_${System.currentTimeMillis()}"
            val mime = ctx.contentResolver.getType(uri) ?: "application/octet-stream"
            val dir = File(ctx.cacheDir, DIR)
            if (!dir.exists()) dir.mkdirs()
            // 文件名里的路径分隔符/冒号这类字符会毁掉落盘路径，替换掉
            val safe = name.replace(Regex("[^A-Za-z0-9._\\-\\u4e00-\\u9fa5]"), "_")
            val out = File(dir, "${System.currentTimeMillis()}_$safe")
            val input = ctx.contentResolver.openInputStream(uri) ?: return null
            input.use { src ->
                out.outputStream().use { dst -> src.copyTo(dst) }
            }
            mapOf(
                "path" to out.absolutePath,
                "name" to name,
                "mime" to mime,
                "size" to out.length().toInt(),
            )
        } catch (e: Exception) {
            Log.w(TAG, "复制分享文件失败：$uri", e)
            null
        }
    }

    private fun displayName(ctx: Context, uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        return try {
            ctx.contentResolver
                .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val i = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (i >= 0) cursor.getString(i) else null
                    } else {
                        null
                    }
                }
        } catch (e: Exception) {
            Log.w(TAG, "取分享文件名失败：$uri", e)
            null
        }
    }
}
