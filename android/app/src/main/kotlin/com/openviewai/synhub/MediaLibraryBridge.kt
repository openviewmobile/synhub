// 本机相册（MediaStore）读取桥 —— 手机自动备份的"源"。
//
// 为什么自己写而不是引 `photo_manager`：
//   * 项目里已经有 KeystoreBridge / MediaOpenBridge / NetworkBridge / LocationBridge
//     这套极小的 MethodChannel 写法，加一个百来行的桥比引一个带一堆 Android
//     依赖的插件干净；
//   * 我们只要三件事：**权限三态**、**枚举整库（图片+视频）**、**把 content uri
//     复制成可上传的文件**。没有相册分组、没有缩略图、没有持续监听。
//
// 权限分支（App targetSdk=36）：
//   * API <= 32：`READ_EXTERNAL_STORAGE`（真机 LGE-AN10 是 Android 12 / API 31）
//   * API >= 33：`READ_MEDIA_IMAGES` + `READ_MEDIA_VIDEO`
//   * API >= 34：另外申请 `READ_MEDIA_VISUAL_USER_SELECTED`（用户可能只选几张）
//
// 回调路径：MainActivity.onRequestPermissionsResult → [onPermissionResult]；
// 系统删除确认框 MainActivity.onActivityResult → [onActivityResult]。
//
// 「释放手机空间」（相册 P51）在 Android 侧就落在这个桥里：
//   * API >= 30 用 `MediaStore.createDeleteRequest` 弹**系统确认框**，用户点允许后
//     我们才 `contentResolver.delete`（**绝不静默删用户照片**）；
//   * API < 30 没有这个能力 → 如实回 `settings_only`，由界面引导去系统设置手动清理；
//   * `openAppSettings` 只跳系统设置页，不删任何东西。
package com.openviewai.synhub

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

object MediaLibraryBridge {
    const val CHANNEL = "synhub/media"
    private const val PERMISSION_REQUEST_CODE = 4312
    private const val DELETE_REQUEST_CODE = 4313
    private const val TAG = "SynologyChatMedia"

    private var pendingResult: MethodChannel.Result? = null
    private var activity: FlutterFragmentActivity? = null

    /** 系统删除确认框还没回时的挂起请求 */
    private var pendingDeleteResult: MethodChannel.Result? = null
    private var pendingDeleteUris: List<Uri> = emptyList()

    fun attach(activity: FlutterFragmentActivity, engine: FlutterEngine) {
        this.activity = activity
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                val ctx = activity.applicationContext
                when (call.method) {
                    "status" -> result.success(status(ctx))
                    "requestPermission" -> requestPermission(activity, result)
                    "list" -> {
                        val includeVideos = call.argument<Boolean>("includeVideos") ?: true
                        val limit = (call.argument<Number>("limit") ?: 500).toInt()
                        val offset = (call.argument<Number>("offset") ?: 0).toInt()
                        result.success(list(ctx, includeVideos, offset, limit))
                    }
                    "materialize" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        val name = call.argument<String>("name") ?: "media"
                        result.success(materialize(ctx, uri, name))
                    }
                    "clearCache" -> {
                        clearCache(ctx)
                        result.success(true)
                    }
                    // ---- 释放手机空间（P51）
                    "deleteSupport" -> result.success(mapOf("support" to deleteSupportId()))
                    "requestDelete" -> {
                        val uris = (call.argument<List<String>>("uris") ?: emptyList<String>())
                            .filter { it.isNotEmpty() }
                            .map { Uri.parse(it) }
                        requestDelete(activity, uris, result)
                    }
                    "openAppSettings" -> result.success(openAppSettings(activity))
                    else -> result.notImplemented()
                }
            }
    }

    fun detach() {
        pendingResult = null
        pendingDeleteResult = null
        pendingDeleteUris = emptyList()
        activity = null
    }

    /** MainActivity 转发系统权限回调；返回 true 表示这次回调是我们的 */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val result = pendingResult ?: return true
        pendingResult = null
        val ctx = activity?.applicationContext
        result.success(if (ctx == null) emptyStatus() else status(ctx))
        return true
    }

    /**
     * MainActivity 转发 `onActivityResult`（系统删除确认框的结局）。
     * 返回 true 表示这次回调是我们的。
     */
    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != DELETE_REQUEST_CODE) return false
        // 用户点了"允许"才会走到真正的删除；取消/返回 → 一项都不删
        finishDelete(confirmed = resultCode == Activity.RESULT_OK)
        return true
    }

    // ------------------------------------------------------------- 权限

    private fun imagePermission(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_IMAGES
        } else {
            @Suppress("DEPRECATION")
            Manifest.permission.READ_EXTERNAL_STORAGE
        }

    private fun videoPermission(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_VIDEO
        } else {
            @Suppress("DEPRECATION")
            Manifest.permission.READ_EXTERNAL_STORAGE
        }

    private fun has(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED

    private fun granted(context: Context): Boolean =
        has(context, imagePermission()) || has(context, videoPermission())

    /** Android 14+ 的"只授权了选中的几张" */
    private fun partial(context: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
            has(context, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) &&
            !has(context, imagePermission())

    private fun emptyStatus(): Map<String, Any?> = mapOf(
        "sdkInt" to Build.VERSION.SDK_INT,
        "granted" to false,
        "partial" to false,
        "imagesGranted" to false,
        "videoGranted" to false,
    )

    private fun status(context: Context): Map<String, Any?> = mapOf(
        "sdkInt" to Build.VERSION.SDK_INT,
        "granted" to granted(context),
        "partial" to partial(context),
        "imagesGranted" to has(context, imagePermission()),
        "videoGranted" to has(context, videoPermission()),
    )

    private fun requestPermission(activity: FlutterFragmentActivity, result: MethodChannel.Result) {
        val ctx = activity.applicationContext
        if (granted(ctx)) {
            result.success(status(ctx))
            return
        }
        if (pendingResult != null) {
            // 上一次还没回（用户还没点授权弹窗）：直接回现状，别排队
            result.success(status(ctx))
            return
        }
        pendingResult = result
        Handler(Looper.getMainLooper()).post {
            ActivityCompat.requestPermissions(
                activity,
                permissionsToRequest(),
                PERMISSION_REQUEST_CODE,
            )
        }
    }

    private fun permissionsToRequest(): Array<String> = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> arrayOf(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO,
            Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
        )
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> arrayOf(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO,
        )
        else -> arrayOf(
            @Suppress("DEPRECATION")
            Manifest.permission.READ_EXTERNAL_STORAGE,
        )
    }

    // ------------------------------------------------------------- 枚举

    private fun list(
        context: Context,
        includeVideos: Boolean,
        offset: Int,
        limit: Int,
    ): Map<String, Any?> {
        if (!granted(context)) {
            return mapOf("items" to emptyList<Any>(), "granted" to false)
        }
        // 分别查 Images / Video 两张表（各自都有 `date_taken`，比 `MediaStore.Files`
        // 跨类型查更稳 —— Files 视图在个别 ROM 上没有 date_taken）。
        val all = mutableListOf<Map<String, Any?>>()
        queryCollection(context, MediaStore.Images.Media.EXTERNAL_CONTENT_URI, false, all)
        if (includeVideos) {
            queryCollection(context, MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true, all)
        }
        all.sortByDescending { (it["takenTime"] as? Long) ?: 0L }
        val page = if (offset >= all.size) {
            emptyList()
        } else {
            all.subList(offset, minOf(all.size, offset + limit)).toList()
        }
        return mapOf("items" to page, "granted" to true)
    }

    private fun queryCollection(
        context: Context,
        collection: Uri,
        isVideo: Boolean,
        out: MutableList<Map<String, Any?>>,
    ) {
        val hasRelativePath = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
        val projection = mutableListOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.MediaColumns.MIME_TYPE,
        )
        if (hasRelativePath) projection.add(MediaStore.MediaColumns.RELATIVE_PATH)
        val sort = "${MediaStore.MediaColumns.DATE_TAKEN} DESC, " +
            "${MediaStore.MediaColumns.DATE_MODIFIED} DESC"
        try {
            context.contentResolver.query(
                collection,
                projection.toTypedArray(),
                null,
                null,
                sort,
            )?.use { c ->
                val idCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val nameCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val sizeCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                val takenCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_TAKEN)
                val modifiedCol =
                    c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
                val mimeCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
                val relCol = if (hasRelativePath) {
                    c.getColumnIndexOrThrow(MediaStore.MediaColumns.RELATIVE_PATH)
                } else {
                    -1
                }
                while (c.moveToNext()) {
                    val id = c.getLong(idCol)
                    val taken = if (c.isNull(takenCol)) 0L else c.getLong(takenCol)
                    // `date_modified` 是**秒**；`date_taken` 是**毫秒**
                    val modified = c.getLong(modifiedCol) * 1000L
                    out.add(
                        mapOf(
                            "id" to "$id",
                            "uri" to ContentUris
                                .withAppendedId(collection, id).toString(),
                            "name" to (c.getString(nameCol) ?: ""),
                            "size" to (if (c.isNull(sizeCol)) 0L else c.getLong(sizeCol)),
                            "takenTime" to (if (taken > 0L) taken else modified),
                            "modifiedTime" to modified,
                            "mime" to (c.getString(mimeCol) ?: ""),
                            "isVideo" to isVideo,
                            "relativePath" to
                                (if (relCol >= 0) (c.getString(relCol) ?: "") else ""),
                        ),
                    )
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "枚举相册失败（${if (isVideo) "video" else "image"}）：${e.message}")
        }
    }

    // ------------------------------------------------------------- 落盘

    private fun cacheDir(context: Context): File =
        File(context.cacheDir, "photo_backup")

    /** 把 content uri 复制到 App 缓存，回可上传的绝对路径（失败 null） */
    private fun materialize(context: Context, uri: String, name: String): String? {
        if (uri.isEmpty()) return null
        val dir = cacheDir(context)
        if (!dir.exists() && !dir.mkdirs()) return null
        // 文件名做白名单化，避免 `../` 之类的路径穿越
        val safe = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
            .takeLast(80)
            .ifEmpty { "media" }
        val out = File(dir, "${System.currentTimeMillis()}_$safe")
        return try {
            context.contentResolver.openInputStream(Uri.parse(uri))?.use { input ->
                FileOutputStream(out).use { output -> input.copyTo(output) }
            } ?: return null
            out.absolutePath
        } catch (e: Exception) {
            Log.w(TAG, "落盘失败：${e.message}")
            null
        }
    }

    private fun clearCache(context: Context) {
        try {
            cacheDir(context).deleteRecursively()
        } catch (e: Exception) {
            Log.w(TAG, "清理临时文件失败：${e.message}")
        }
    }

    // --------------------------------------------------- 释放手机空间（P51）

    /** `system_confirm` = API 30+ 能弹系统确认框；否则只能引导去系统设置 */
    private fun deleteSupportId(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            "system_confirm"
        } else {
            "settings_only"
        }

    /**
     * 请求删除本地相册文件。
     *
     * **必然经过系统确认框**：API 30+ 走 `MediaStore.createDeleteRequest`，
     * 用户在弹框上点"允许"后才调 `ContentResolver.delete`；点取消/返回 → 一项都不删。
     * API < 30 直接回 `settings_only` + `confirmed=false`，**绝不静默删除**。
     */
    private fun requestDelete(
        activity: FlutterFragmentActivity,
        uris: List<Uri>,
        result: MethodChannel.Result,
    ) {
        fun nothingDeleted(error: String): Map<String, Any?> = mapOf(
            "support" to deleteSupportId(),
            "confirmed" to false,
            "requested" to uris.size,
            "deleted" to emptyList<String>(),
            "failed" to uris.map { it.toString() },
            "error" to error,
        )
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.success(nothingDeleted("settings-only"))
            return
        }
        if (uris.isEmpty()) {
            result.success(
                mapOf(
                    "support" to deleteSupportId(),
                    "confirmed" to false,
                    "requested" to 0,
                    "deleted" to emptyList<String>(),
                    "failed" to emptyList<String>(),
                    "error" to "",
                ),
            )
            return
        }
        if (pendingDeleteResult != null) {
            // 上一次确认框还没回：不排队，如实回"什么都没删"
            result.success(nothingDeleted("delete-in-flight"))
            return
        }
        pendingDeleteResult = result
        pendingDeleteUris = uris
        Handler(Looper.getMainLooper()).post {
            try {
                val request = MediaStore.createDeleteRequest(activity.contentResolver, uris)
                ActivityCompat.startIntentSenderForResult(
                    activity,
                    request.intentSender,
                    DELETE_REQUEST_CODE,
                    null,
                    0,
                    0,
                    0,
                    // 末位 `options: Bundle?` 是 androidx.core 新版多出来的参数
                    null,
                )
            } catch (e: Exception) {
                Log.w(TAG, "请求删除相册文件失败：${e.message}")
                finishDelete(confirmed = false, error = e.message ?: "request-failed")
            }
        }
    }

    /** 系统确认框的结局 → 该批文件真正的删除结果（只有确认过才真删） */
    private fun finishDelete(confirmed: Boolean, error: String? = null) {
        val result = pendingDeleteResult
        val uris = pendingDeleteUris
        pendingDeleteResult = null
        pendingDeleteUris = emptyList()
        if (result == null) return
        if (!confirmed) {
            result.success(
                mapOf(
                    "support" to deleteSupportId(),
                    "confirmed" to false,
                    "requested" to uris.size,
                    "deleted" to emptyList<String>(),
                    "failed" to uris.map { it.toString() },
                    "error" to (error ?: ""),
                ),
            )
            return
        }
        val resolver = activity?.applicationContext?.contentResolver
        val deleted = mutableListOf<String>()
        val failed = mutableListOf<String>()
        for (uri in uris) {
            try {
                val rows = resolver?.delete(uri, null, null) ?: 0
                if (rows > 0) deleted.add(uri.toString()) else failed.add(uri.toString())
            } catch (e: Exception) {
                Log.w(TAG, "删除失败：${e.message}")
                failed.add(uri.toString())
            }
        }
        result.success(
            mapOf(
                "support" to deleteSupportId(),
                "confirmed" to true,
                "requested" to uris.size,
                "deleted" to deleted,
                "failed" to failed,
                "error" to "",
            ),
        )
    }

    /** 跳系统设置的应用详情页（用户手动清理的降级路径）；打不开回 false */
    private fun openAppSettings(activity: FlutterFragmentActivity): Boolean = try {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", activity.packageName, null),
        )
        activity.startActivity(intent)
        true
    } catch (e: Exception) {
        Log.w(TAG, "打开系统设置失败：${e.message}")
        false
    }
}
