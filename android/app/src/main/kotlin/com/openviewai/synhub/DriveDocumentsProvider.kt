// ★★ ③Drive 第 213 轮 **D66「SAF / ContentProvider 暴露」** 的 Kotlin 半边。
//
// ## 官方对照（`SynologyDrive 3.9.0-1113` smali：`provider/DriveDocumentsProvider.smali`）
//
// 官方是一个完整的 `android.provider.DocumentsProvider`：
//   authority `com.synology.dsdrive.documents`；
//   `queryRoots` / `queryDocument` / `queryChildDocuments` / `querySearchDocuments` /
//   `openDocument` / `openDocumentThumbnail` / `openTypedDocument` / `createDocument`；
//   文档 id 方案 `virtualTop` + `:real:`（远端文件）/ `:label:`（标签视图）/
//   `:local:`（本地副本）/ `:create_folder:`（新建目录）；
//   列 `_display_name` / `_size` / `last_modified` / `mime_type` / `icon` /
//   `flags` / `summary` / `title` / `root_id` / `document_id`；
//   还有 `checkLoginStatus` / `getNeedGDPRAgreedMatrixCursor` /
//   `getLoadingMatrixCursor` 三种**占位游标**（未登录 / 未同意 GDPR / 加载中）。
//
// ## 本实现的**范围**（如实登记，别当成"全做完了"）
//
//   * **做**：`queryRoots` / `queryDocument` / `queryChildDocuments` /
//     `querySearchDocuments` / `openDocument` / `openDocumentThumbnail` /
//     `createDocument`（**只报错**，见下）+ `:local:` / `:real:` / `:label:` /
//     `virtualTop` / `:create_folder:` 的 id **编解码**（与官方逐字一致）。
//   * **数据面**：读 Dart 侧写好的**索引 JSON**
//     （`<dataDir>/app_flutter/saf/drive_index.json`，契约见
//     `lib/src/features/files/drive_saf_index.dart`），里面**只有真正缓存到本地
//     的离线文件** —— 与官方 `:local:` 语义一致。
//   * **221 轮已做**：`:real:` 的**远端目录树镜像**（Dart 侧写索引）⇒ 可浏览/搜索；
//   * **不做（明确待办）**：`:real:` 的**按需下载后打开**（provider 不自登录 DSM）
//     （那要 provider 自己在冷启动时登录 DSM：QuickConnect + TLS + 凭据存储，
//     官方是把自己的 SDK 塞进 provider 里的）；`:label:` 标签视图；
//     三种占位游标；`createDocument` 真建目录。
//     `createDocument` 现在**如实抛异常**（`FileNotFoundException`），
//     不假装成功 —— 系统选择器会看到"只读"。
//
// ## 为什么用 JSON 文件而不是走 MethodChannel
// SAF 的 provider 可能由**系统文件选择器**在 Flutter 引擎**没起来**时拉起
// （例如用户从「文件」App 里进来）。这时候 MethodChannel 没有对端，
// 所以索引必须落在**两边都能读的磁盘文件**上。Dart 侧的
// `SafIndexEntry.localPath` 就是 `openDocument` 用的真实路径。
package com.openviewai.synhub

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import java.io.File
import java.io.FileNotFoundException
import org.json.JSONObject

class DriveDocumentsProvider : DocumentsProvider() {

    companion object {
        /** 与 Dart 侧 `safAuthority` 必须一致（`drive_saf_index.dart`）。 */
        const val AUTHORITY = "com.openviewai.synhub.drive.documents"

        /** 官方虚拟根 id（smali 常量 `virtualTop`）。 */
        const val ROOT_ID = "virtualTop"

        const val PREFIX_REAL = ":real:"
        const val PREFIX_LABEL = ":label:"
        const val PREFIX_LOCAL = ":local:"
        const val PREFIX_CREATE_FOLDER = ":create_folder:"

        const val MIME_DIR = DocumentsContract.Document.MIME_TYPE_DIR
        const val DEFAULT_MIME = "*/*"

        /** Dart 侧 `safIndexFileName`。 */
        const val INDEX_FILE = "drive_index.json"

        /**
         * 文档级 flags：`FLAG_LOCAL_ONLY` 是 **Root** 的旗标，Document 这一层
         * 没有"只本地"这一位；所以文档行只用 `FLAG_SUPPORTS_THUMBNAIL`
         * （根那一行才带 `Root.FLAG_LOCAL_ONLY`）。
         */
        private const val FLAG_LOCAL = 0
        private const val FLAG_THUMB = DocumentsContract.Document.FLAG_SUPPORTS_THUMBNAIL

        private val DEFAULT_ROOT_PROJECTION = arrayOf(
            DocumentsContract.Root.COLUMN_ROOT_ID,
            DocumentsContract.Root.COLUMN_MIME_TYPES,
            DocumentsContract.Root.COLUMN_FLAGS,
            DocumentsContract.Root.COLUMN_ICON,
            DocumentsContract.Root.COLUMN_TITLE,
            DocumentsContract.Root.COLUMN_SUMMARY,
            DocumentsContract.Root.COLUMN_DOCUMENT_ID,
            DocumentsContract.Root.COLUMN_AVAILABLE_BYTES,
        )

        private val DEFAULT_DOC_PROJECTION = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_FLAGS,
            DocumentsContract.Document.COLUMN_SIZE,
        )
    }

    /** 索引文件：`<dataDir>/app_flutter/saf/drive_index.json`（Dart 侧契约）。 */
    private fun indexFile(): File =
        File(File(context!!.filesDir.parentFile, "app_flutter/saf"), INDEX_FILE)

    private fun loadIndex(): JSONObject? = try {
        val f = indexFile()
        if (!f.isFile) null else JSONObject(f.readText())
    } catch (_: Exception) {
        null
    }

    /** 索引里的一条；`local_path` 必须**真实存在**才可用（防编造）。 */
    private data class Entry(
        val documentId: String,
        val name: String,
        val mimeType: String,
        val size: Long,
        val lastModified: Long,
        val localPath: String,
    )

    private fun entries(index: JSONObject?): List<Entry> {
        val arr = index?.optJSONArray("entries") ?: return emptyList()
        val out = ArrayList<Entry>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val path = o.optString("local_path", "")
            val id = o.optString("document_id", "")
            if (id.isEmpty()) continue
            // ★ 本地副本不存在就不暴露（否则用户点开是 404）
            if (path.isNotEmpty() && !File(path).isFile) continue
            out.add(
                Entry(
                    documentId = id,
                    name = o.optString("name", File(path).name),
                    mimeType = o.optString("mime_type", DEFAULT_MIME),
                    size = o.optLong("size", 0L),
                    lastModified = o.optLong("last_modified", 0L),
                    localPath = path,
                )
            )
        }
        return out
    }

    private fun findById(documentId: String): Entry? =
        entries(loadIndex()).firstOrNull { it.documentId == documentId }

    override fun onCreate(): Boolean = true

    /** `queryRoots`：官方根有若干档；我们只暴露"离线文件"这一档（`FLAG_LOCAL_ONLY`）。 */
    override fun queryRoots(projection: Array<String>?): Cursor {
        val cols = projection ?: DEFAULT_ROOT_PROJECTION
        val cursor = MatrixCursor(cols)
        val index = loadIndex()
        val title = index?.optString("root_title", "")
            ?.takeIf { it.isNotEmpty() } ?: "Synology Drive · 离线文件"
        val count = entries(index).size
        cursor.newRow().apply {
            for (col in cols) {
                when (col) {
                    DocumentsContract.Root.COLUMN_ROOT_ID -> add(ROOT_ID)
                    DocumentsContract.Root.COLUMN_DOCUMENT_ID -> add(ROOT_ID)
                    DocumentsContract.Root.COLUMN_TITLE -> add(title)
                    DocumentsContract.Root.COLUMN_SUMMARY -> add("$count 个文件")
                    DocumentsContract.Root.COLUMN_MIME_TYPES -> add(DEFAULT_MIME)
                    // 只读 + 只本地：不报 SUPPORTS_CREATE / SUPPORTS_RECENTS 之类
                    DocumentsContract.Root.COLUMN_FLAGS -> add(
                        DocumentsContract.Root.FLAG_LOCAL_ONLY or
                            DocumentsContract.Root.FLAG_SUPPORTS_SEARCH
                    )
                    DocumentsContract.Root.COLUMN_ICON -> add(android.R.drawable.ic_menu_upload)
                    DocumentsContract.Root.COLUMN_AVAILABLE_BYTES -> add(null)
                }
            }
        }
        return cursor
    }

    private fun rowFor(cursor: MatrixCursor, cols: Array<String>, e: Entry) {
        cursor.newRow().apply {
            for (col in cols) {
                when (col) {
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID -> add(e.documentId)
                    DocumentsContract.Document.COLUMN_MIME_TYPE -> add(e.mimeType)
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME -> add(e.name)
                    DocumentsContract.Document.COLUMN_SIZE -> add(e.size)
                    // ★ r368 修 DA20：SAF 契约里 `COLUMN_LAST_MODIFIED` 是**毫秒**，
                    // 索引里的 `last_modified` 是服务端的 **epoch 秒** —— 直接透传
                    // 会让系统选择器显示成 1970-01-xx（真机实测 "Jan 22, 1970"）。
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED -> add(
                        if (e.lastModified > 0) e.lastModified * 1000L else 0L,
                    )
                    DocumentsContract.Document.COLUMN_FLAGS -> add(FLAG_LOCAL or FLAG_THUMB)
                    else -> add(null)
                }
            }
        }
    }

    override fun queryDocument(
        documentId: String,
        projection: Array<String>?,
    ): Cursor {
        val cols = projection ?: DEFAULT_DOC_PROJECTION
        val cursor = MatrixCursor(cols)
        if (documentId == ROOT_ID) {
            // 虚拟根：官方由 `getChildCursorForVirtualTop` 给一行"根目录"自己
            cursor.newRow().apply {
                for (col in cols) {
                    when (col) {
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID -> add(ROOT_ID)
                        DocumentsContract.Document.COLUMN_MIME_TYPE -> add(MIME_DIR)
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME -> add("离线文件")
                        DocumentsContract.Document.COLUMN_FLAGS -> add(FLAG_LOCAL)
                        else -> add(null)
                    }
                }
            }
            return cursor
        }
        val e = findById(documentId) ?: throw FileNotFoundException("未知文档 id: $documentId")
        rowFor(cursor, cols, e)
        return cursor
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<String>?,
        sortOrder: String?,
    ): Cursor {
        val cols = projection ?: DEFAULT_DOC_PROJECTION
        val cursor = MatrixCursor(cols)
        // 本批是**平铺**的离线文件清单（官方按 Drive 目录树展开，见待办）
        if (parentDocumentId == ROOT_ID) {
            for (e in entries(loadIndex())) rowFor(cursor, cols, e)
        }
        return cursor
    }

    override fun querySearchDocuments(
        rootId: String,
        query: String,
        projection: Array<String>?,
    ): Cursor {
        val cols = projection ?: DEFAULT_DOC_PROJECTION
        val cursor = MatrixCursor(cols)
        val q = query.lowercase()
        for (e in entries(loadIndex())) {
            if (e.name.lowercase().contains(q)) rowFor(cursor, cols, e)
        }
        return cursor
    }

    /** ★ 只读：官方能建目录，我们**如实失败**（不假装成功）。 */
    override fun createDocument(
        parentDocumentId: String,
        mimeType: String,
        displayName: String,
    ): String {
        throw FileNotFoundException("本 provider 目前只读：不支持新建（离线文件由 App 登记）")
    }

    override fun deleteDocument(documentId: String) {
        throw FileNotFoundException("本 provider 目前只读：不支持删除")
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        val e = findById(documentId) ?: throw FileNotFoundException("未知文档 id: $documentId")
        // ★ 221 轮：`:real:`（云端镜像）条目在**本地有副本**时也能开。
        // ★ 246 轮 D66：没有副本时**自己登录 DSM 现下**（provider 冷启动也能用），
        //   与 Dart 侧 `DriveOpenOnDemand` 共用同一缓存目录/文件名约定。
        if (e.localPath.isEmpty()) {
            val f2 = openOnDemand(e, documentId)
            if (mode.contains("w")) {
                throw FileNotFoundException("本 provider 目前只读")
            }
            return ParcelFileDescriptor.open(f2, ParcelFileDescriptor.MODE_READ_ONLY)
        }
        val f = File(e.localPath)
        if (!f.isFile) throw FileNotFoundException("本地副本不在: ${e.localPath}")
        // 只允许读（不实现 "w"）
        if (mode.contains("w")) {
            throw FileNotFoundException("本 provider 目前只读")
        }
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    /// ★ 246 轮 D66：`openDocument` 时本地没有副本 ⇒ **现下**。
    ///
    /// 哪来的 fileId：`:real:<fileId>` / `:local:<fileId>` 里的 id 段；
    /// `virtualTop` 这类虚拟节点没有 fileId ⇒ 如实报错。
    private fun openOnDemand(e: Entry, documentId: String): File {
        val fileId = extractFileId(documentId)
        if (fileId.isEmpty()) {
            throw FileNotFoundException(
                "「${e.name}」不是可下载的文件节点（$documentId）"
            )
        }
        return try {
            DriveSafSession.download(context ?: throw FileNotFoundException("provider 没有 context"), fileId, e.name)
        } catch (ex: Exception) {
            // 未配置凭据 / 未开启 / 网络失败 —— **如实报错**，不假装打开
            throw FileNotFoundException(
                "「${e.name}」按需下载失败：${ex.message ?: ex.toString()}"
            )
        }
    }

    /**
     * 从文档 id 里抽 fileId（`:real:<id>` / `:local:<id>`）。
     *
     * ⚠️ **247 轮真机抓到的 bug**：上一版写成"取第一个冒号到下一个冒号之间的段"，
     * 于是 `:real:drive-demo-1` 被解析成 **`real`**（那是**标签**不是 id），
     * 下载请求带着 `files=["id:real"]` 打到服务端 ⇒ **408 文件不存在**。
     * 官方 smali 的前缀是**定长已知**的，必须**逐前缀剥掉**，不能靠"找冒号"。
     */
    private fun extractFileId(documentId: String): String = when {
        documentId.startsWith(PREFIX_REAL) -> documentId.substring(PREFIX_REAL.length)
        documentId.startsWith(PREFIX_LOCAL) -> documentId.substring(PREFIX_LOCAL.length)
        // `:label:` / `:create_folder:` / `virtualTop` 都不是可下载的文件节点
        else -> ""
    }

    override fun openDocumentThumbnail(
        documentId: String,
        sizeHint: android.graphics.Point?,
        signal: CancellationSignal?,
    ): android.content.res.AssetFileDescriptor {
        // 官方会按需生成缩略图；我们直接把**原文件**交出去（系统会自己缩放）。
        val e = findById(documentId) ?: throw FileNotFoundException("未知文档 id: $documentId")
        val f = File(e.localPath)
        if (!f.isFile) throw FileNotFoundException("本地副本不在: ${e.localPath}")
        // 交原文件（不在这里 close：AssetFileDescriptor 的生命周期由调用方管）
        val pfd = ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
        return android.content.res.AssetFileDescriptor(
            pfd,
            0L,
            android.content.res.AssetFileDescriptor.UNKNOWN_LENGTH,
        )
    }
}
