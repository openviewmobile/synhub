// 用「带 MIME 类型」的 ACTION_VIEW 把流媒体/附件交给外部应用打开。
//
// 对齐原版 `util/VideoUtil.openStreaming` + `util/FileUtil.showMimeTypeDialog`：
//   * 原版拿到 `getStreamingUrlOfPostId(postId)`（带 `_sid` 的 http 直链）后，
//     用 `Intent(ACTION_VIEW).setDataAndType(uri, mimeTypeFromExtension(文件名))`
//     交给系统；**必须带 type**，否则 `.mp4` 往往被浏览器接走而不是视频播放器。
//   * `url_launcher` 只能发不带 type 的 ACTION_VIEW，所以这里自己开一个 channel。
//   * 没有任何应用能处理该 mime 时返回 false，Dart 侧再弹「打开方式」
//     （原版 `FileUtil.showMimeTypeDialog`：text/* / audio/* / video/* / image/*）。
package com.openviewai.synhub

import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ResolveInfo
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

object MediaOpenBridge {
    const val CHANNEL = "synhub/media_open"
    private const val TAG = "SynologyChatMedia"

    fun attach(context: Context, engine: FlutterEngine) {
        val appContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "view" -> {
                        val url = call.argument<String>("url").orEmpty()
                        val mime = call.argument<String>("mime").orEmpty()
                        if (url.isEmpty()) {
                            result.error("bad_args", "url 不能为空", null)
                            return@setMethodCallHandler
                        }
                        result.success(view(appContext, url, mime))
                    }
                    // 本地文件（下载到 cache/files 之后）交给系统应用：带**显式
                    // MIME** 的 ACTION_VIEW。Dart 侧 `systemOpen` 走这条（而不是
                    // `open_filex`）：后者的内置 MIME 表没有 mkv/webm/flac…，
                    // 落回 `*/*` 后在华为/HONOR ROM 上会被
                    // `com.android.packageinstaller/.InstallStart` 接走。
                    "viewLocal" -> {
                        val path = call.argument<String>("path").orEmpty()
                        val mime = call.argument<String>("mime").orEmpty()
                        if (path.isEmpty()) {
                            result.error("bad_args", "path 不能为空", null)
                            return@setMethodCallHandler
                        }
                        result.success(viewLocal(appContext, path, mime))
                    }
                    // 存进系统「下载」目录（原版 DownloadFragment 的 DOWNLOAD：
                    // FileUtil.moveFileToPublicDownloadDir + DownloadManager）
                    "saveToDownloads" -> {
                        val path = call.argument<String>("path").orEmpty()
                        val name = call.argument<String>("name").orEmpty()
                        val mime = call.argument<String>("mime").orEmpty()
                        if (path.isEmpty() || name.isEmpty()) {
                            result.error("bad_args", "path/name 不能为空", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(saveToDownloads(appContext, path, name, mime))
                        } catch (e: Exception) {
                            Log.w(TAG, "存到下载目录失败：${e.message}")
                            result.error("save_failed", e.message, null)
                        }
                    }
                    // 分享（原版 DOWNLOAD_SHARE：ACTION_SEND + FileProvider）
                    "share" -> {
                        val path = call.argument<String>("path").orEmpty()
                        val name = call.argument<String>("name").orEmpty()
                        val mime = call.argument<String>("mime").orEmpty()
                        if (path.isEmpty()) {
                            result.error("bad_args", "path 不能为空", null)
                            return@setMethodCallHandler
                        }
                        result.success(share(appContext, path, name, mime))
                    }
                    // 只问"有没有应用能接这个分享"（真机验收用，无副作用）
                    "canShare" -> {
                        val path = call.argument<String>("path").orEmpty()
                        val mime = call.argument<String>("mime").orEmpty()
                        result.success(path.isNotEmpty() &&
                            !queryShareTargets(appContext, path, mime).isEmpty())
                    }
                    // 分享纯文本（分享链接「发送」用）。
                    //
                    // 为什么必须有它：官方 DS file 的分享链接是 `email_link_context`
                    // + `Intent.createChooser`（任意 App 都能接），而既有的 `share`
                    // 只能发**本地文件**（FileProvider + EXTRA_STREAM），
                    // 发不了纯文本/URL；`url_launcher` 的 mailto 只能覆盖邮件客户端。
                    // 这里补 `ACTION_SEND` + `EXTRA_TEXT`/`EXTRA_SUBJECT`，
                    // 与官方同构（**不新开通道**，仍走 MediaOpenBridge 的既有 channel）。
                    "shareText" -> {
                        val text = call.argument<String>("text").orEmpty()
                        val subject = call.argument<String>("subject").orEmpty()
                        if (text.isEmpty()) {
                            result.error("bad_args", "text 不能为空", null)
                            return@setMethodCallHandler
                        }
                        result.success(shareText(appContext, text, subject))
                    }
                    // ★ 邮件带附件（官方 DSnote `NoteFragment.sendMailText`
                    // = `ACTION_SEND_MULTIPLE` + 多个 FileProvider uri）。
                    // mailto: 本体**带不了附件**，所以官方在"笔记有附件"时改走
                    // 隐式 `SEND_MULTIPLE` 选择器（标题仍是 `email_note`）。
                    // 这里与官方同构：多文件、`EXTRA_STREAM` 列表、
                    // `FLAG_GRANT_READ_URI_PERMISSION`。
                    "shareFiles" -> {
                        val paths = call.argument<List<String>>("paths").orEmpty()
                            .filter { it.isNotEmpty() }
                        val text = call.argument<String>("text").orEmpty()
                        val subject = call.argument<String>("subject").orEmpty()
                        val mime = call.argument<String>("mime").orEmpty()
                        if (paths.isEmpty()) {
                            result.error("bad_args", "paths 不能为空", null)
                            return@setMethodCallHandler
                        }
                        result.success(shareFiles(appContext, paths, text, subject, mime))
                    }
                    // 清场用：删掉上面存进 MediaStore 的那一行
                    "deleteSaved" -> {
                        val uri = call.argument<String>("uri").orEmpty()
                        result.success(deleteSaved(appContext, uri))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ------------------------------------------------------- 存到「下载」

    /**
     * 把 [path] 里的文件复制进系统公共「下载」目录。
     *
     * API 29+ 用 MediaStore（scoped storage，不需要权限）；更老的直接写
     * `Environment.getExternalStoragePublicDirectory(DIRECTORY_DOWNLOADS)`
     * （manifest 里那个 `WRITE_EXTERNAL_STORAGE` 只声明到 API 28）。
     * 返回 MediaStore 的 uri 字符串（老系统返回 `file://` 路径）。
     */
    private fun saveToDownloads(
        context: Context,
        path: String,
        name: String,
        mime: String,
    ): String? {
        val mimeType = mime.ifEmpty { "application/octet-stream" }
        val source = File(path)
        if (!source.exists()) {
            Log.w(TAG, "源文件不存在：$path")
            return null
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mimeType)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val target = resolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: return null
            try {
                resolver.openOutputStream(target)?.use { out ->
                    source.inputStream().use { it.copyTo(out) }
                } ?: return null
            } catch (e: Exception) {
                resolver.delete(target, null, null)
                throw e
            }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(target, values, null, null)
            return target.toString()
        }
        @Suppress("DEPRECATION")
        val dir = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS)
        if (!dir.exists() && !dir.mkdirs()) return null
        val target = File(dir, name)
        source.inputStream().use { input ->
            target.outputStream().use { input.copyTo(it) }
        }
        return Uri.fromFile(target).toString()
    }

    private fun deleteSaved(context: Context, uri: String): Boolean {
        if (uri.isEmpty()) return false
        return try {
            val parsed = Uri.parse(uri)
            if (parsed.scheme == "content") {
                context.contentResolver.delete(parsed, null, null) > 0
            } else {
                File(parsed.path ?: return false).delete()
            }
        } catch (e: Exception) {
            Log.w(TAG, "删除失败：${e.message}")
            false
        }
    }

    // ------------------------------------------------------------ 分享

    private fun shareUri(context: Context, path: String): Uri = FileProvider.getUriForFile(
        context,
        "${context.packageName}.fileprovider",
        File(path),
    )

    /**
     * 分享**多个本地文件**（官方 DSnote `sendMailText` 的
     * `ACTION_SEND_MULTIPLE` 对应物，第 111 轮）。
     *
     * 与 [share] 的区别：那个只发**一个**文件且 `type` 由调用方定；
     * 这里发**一组**附件，并把正文（笔记 HTML/纯文本）放进
     * `EXTRA_TEXT`、标题放进 `EXTRA_SUBJECT` —— 与官方
     * `sendMailText(String text, List<String> attachments)` 逐字对应。
     *
     * 返回 true = 选择器已拉起；false = 没有应用能接（Dart 侧提示"发送失败"）。
     * 单个文件建不出 `content://`（FileProvider 未覆盖的目录）时**跳过它**，
     * 全跳过则返回 false —— 不抛异常，别让一封邮件因为一个附件挂掉。
     */
    private fun shareFiles(
        context: Context,
        paths: List<String>,
        text: String,
        subject: String,
        mime: String,
    ): Boolean {
        val uris = ArrayList<Uri>()
        for (p in paths) {
            try {
                uris.add(shareUri(context, p))
            } catch (e: IllegalArgumentException) {
                Log.w(TAG, "附件跳过（建不出 content://）：$p - ${e.message}")
            }
        }
        if (uris.isEmpty()) return false
        val send = Intent(Intent.ACTION_SEND_MULTIPLE).apply {
            type = mime.ifEmpty { "*/*" }
            putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
            if (text.isNotEmpty()) putExtra(Intent.EXTRA_TEXT, text)
            if (subject.isNotEmpty()) putExtra(Intent.EXTRA_SUBJECT, subject)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        if (context.packageManager.queryIntentActivities(send, 0).isEmpty()) {
            Log.w(TAG, "没有应用能接多附件分享")
            return false
        }
        val chooser = Intent.createChooser(send, subject.ifEmpty { null }).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return try {
            context.startActivity(chooser)
            true
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "多附件分享失败：${e.message}")
            false
        }
    }

    /**
     * 分享**纯文本**（分享链接的「发送」）。
     *
     * 返回 true = 分享面板已拉起；false = 没有任何应用能接（Dart 侧提示"发送失败"）。
     * 与官方 DS file 的 `email_link_context` + `createChooser` 等价：
     * 不限定邮件客户端，任意能收 `text/plain` 的 App 都可选。
     */
    private fun shareText(context: Context, text: String, subject: String): Boolean {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
            if (subject.isNotEmpty()) putExtra(Intent.EXTRA_SUBJECT, subject)
        }
        if (context.packageManager.queryIntentActivities(send, 0).isEmpty()) {
            Log.w(TAG, "没有应用能接文本分享")
            return false
        }
        val chooser = Intent.createChooser(send, subject.ifEmpty { null }).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            context.startActivity(chooser)
            true
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "文本分享失败：${e.message}")
            false
        }
    }

    private fun queryShareTargets(context: Context, path: String, mime: String): List<ResolveInfo> {
        val uri = shareUri(context, path)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mime.ifEmpty { "*/*" }
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return context.packageManager.queryIntentActivities(intent, 0)
    }

    /** 返回 true = 分享面板已拉起；false = 没有应用能接 */
    private fun share(context: Context, path: String, name: String, mime: String): Boolean {
        val uri = shareUri(context, path)
        val type = mime.ifEmpty { "*/*" }
        val send = Intent(Intent.ACTION_SEND).apply {
            setType(type)
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_TITLE, name)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        if (context.packageManager.queryIntentActivities(send, 0).isEmpty()) {
            Log.w(TAG, "没有应用能接分享：$type")
            return false
        }
        val chooser = Intent.createChooser(send, name).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return try {
            context.startActivity(chooser)
            true
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "分享失败：${e.message}")
            false
        }
    }

    /** 返回 true = 已经交给某个应用；false = 没有应用能处理（Dart 侧按失败处理） */
    private fun view(context: Context, url: String, mime: String): Boolean {        val uri = Uri.parse(url)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            // 原版把同一批 URL 也塞进 video_list（部分播放器认这个约定）
            putExtra("video_list", arrayOf(uri))
        }
        val handlers = context.packageManager.queryIntentActivities(intent, 0)
        if (handlers.isEmpty()) {
            Log.w(TAG, "没有应用能处理 $mime：$url")
            return false
        }
        return try {
            context.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "startActivity 失败：${e.message}")
            false
        }
    }

    /**
     * 本地文件 → 系统应用（`ACTION_VIEW` + FileProvider + **显式 MIME**）。
     *
     * 与 [view] 的差别只有"数据源"：这里是 `content://`（本地文件），[view] 是
     * `http(s)://`（直链）。两者都**必须**带准 MIME —— 类型为空或通配 MIME 时，
     * 华为/HONOR ROM 的 `com.android.packageinstaller/.InstallStart` 会以
     * "只有它声明了裸 file/content scheme"的身份独吞这个 intent，于是既不弹
     * 选择器也打不开（真机 `.mkv` 的表现；`.mp4` 有 `video/mp4` 就正常）。
     *
     * 多个 handler 时走 `Intent.createChooser`，与 `.mp4` 的
     * `Complete action using` 完全一致。
     */
    private fun viewLocal(context: Context, path: String, mime: String): Boolean {
        val file = File(path)
        if (!file.exists()) {
            Log.w(TAG, "文件不存在：$path")
            return false
        }
        val typed = resolveMime(path, mime)
        val uri = try {
            FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                file,
            )
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "FileProvider 拿不到 uri：${e.message}")
            return false
        }
        // 先用精确 MIME；ROM 里没有它的 handler 时退到 `video/*` / `audio/*`
        // ——都**不**退 `*/*`（那正是被 InstallStart 接走的原因）。
        val candidates = buildList {
            add(typed)
            val topLevel = typed.substringBefore('/')
            if (topLevel == "video" || topLevel == "audio") add("$topLevel/*")
        }
        var picked: Intent? = null
        var handlers = 0
        for (type in candidates) {
            val candidate = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, type)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val found = context.packageManager.queryIntentActivities(candidate, 0)
            if (found.isNotEmpty()) {
                picked = candidate
                handlers = found.size
                break
            }
        }
        val chosen = picked ?: run {
            Log.w(TAG, "没有应用能处理 $typed（也没有 video/* / audio/* 兜底）：$path")
            return false
        }
        val launch = if (handlers > 1) {
            Intent.createChooser(chosen, null).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        } else {
            chosen
        }
        return try {
            context.startActivity(launch)
            true
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "startActivity 失败：${e.message}")
            false
        }
    }

    /**
     * Dart 侧已按扩展名给准 MIME（`externalOpenMimeOf`）；这里只兜底：
     * 显式值 → 系统 `MimeTypeMap` → 本地小表 → 通配 MIME。
     *
     * `MimeTypeMap` 在 API 21+ 就认识 `mkv`（`video/x-matroska`），但部分
     * ROM 的表被裁剪，所以再兜一层常见的视频/音频扩展名。
     */
    private fun resolveMime(path: String, mime: String): String {
        if (mime.isNotEmpty()) return mime
        val ext = path.substringAfterLast('.', "").lowercase()
        if (ext.isEmpty()) return "*/*"
        android.webkit.MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(ext)?.let { return it }
        return fallbackMimes[ext] ?: "*/*"
    }

    /** `MimeTypeMap` 被 ROM 裁剪时的兜底（只列常见、且 open_filex 表里没有的） */
    private val fallbackMimes = mapOf(
        "mkv" to "video/x-matroska",
        "webm" to "video/webm",
        "flv" to "video/x-flv",
        "ts" to "video/mp2t",
        "rmvb" to "application/vnd.rn-realmedia-vbr",
        "flac" to "audio/flac",
        "opus" to "audio/opus",
        "ape" to "audio/x-ape",
    )
}
