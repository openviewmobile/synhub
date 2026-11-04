// 本机 HTTP 回环代理：把 NAS 上的**完整文件**（支持 Range）喂给平台
// `MediaMetadataRetriever`（第 296 轮）。
//
// ## 为什么需要它
// File Station 的视频缩略图原来只把 **6 MiB 头部**下成本地文件再抽帧 ⇒
// `moov` 在文件尾的大 mp4 / 4.4 GB 的 MKV 一律抽不出真帧（真机实测：
// `stage=frame` 无帧，或首帧是黑色引导场 luma≈0）。而真 NAS **支持 Range**
// （实测 `Range: bytes=0-6291455` → `206` + `Content-Range`）。
//
// 所以这里在 `127.0.0.1` 起一个**回环代理**：`MediaMetadataRetriever.setDataSource`
// 一个 `http://127.0.0.1:<port>/v/<token>`，平台用 Range 请求要哪一段、
// 我们就把哪一段原样转给真 NAS（`HttpsURLConnection`），**不把整份文件读进内存**。
//
// ## ★ 为什么不直接给 retriever 那个 https URL
// `MediaPlayerBridge.setTlsPolicy` 装的是**全局** `HttpsURLConnection`
// `setDefaultHostnameVerifier` / `setDefaultSSLSocketFactory`（窄：只放宽
// 我们自己那台 NAS 主机 + 可选的指纹钉住）。**这个放宽政策只对
// `HttpsURLConnection` 生效**，对平台媒体栈自带的 HTTP 实现不生效。
// 走本代理后：retriever 连的是**明文 http://127.0.0.1**（本机回环，无 TLS），
// 真正带 TLS 的那一跳由**这里的 `HttpsURLConnection`** 发起 ⇒ 自动继承
// `setTlsPolicy` 的放宽政策。这就是"选代理而不是 URL 直连"的原因。
//
// ## 边界
//   * **不申请任何新权限**（回环 socket 不需要权限；`INTERNET` 早已有）；
//   * **不新建插件工程**：单文件 `object`，被 `VideoFrameBridge` 直接调用；
//   * 只做 GET（HEAD 也不写 body）；连不上 / 超时 / 回包异常**只记日志、关连接**，
//     绝不让线程抛穿。
//   * 只绑 `127.0.0.1`，不对外暴露（不绑 `0.0.0.0`）。
package com.openviewai.synhub

import android.util.Log
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.net.ssl.HttpsURLConnection

object LocalRangeProxy {
    /** logcat tag：`adb logcat -s LocalRangeProxy`。 */
    private const val TAG = "LocalRangeProxy"

    /** 连接 NAS 的建连超时 */
    private const val CONNECT_TIMEOUT_MS = 15_000

    /** 读 NAS 回包的超时（大文件分片读取，30s 是每段的空闲上限，不是整份文件） */
    private const val READ_TIMEOUT_MS = 30_000

    /** body 转发缓冲（64 KiB；**绝不整份读进内存**） */
    private const val COPY_BUFFER_BYTES = 64 * 1024

    /** 请求头最大长度（防脏客户端耗内存） */
    private const val MAX_HEADER_BYTES = 64 * 1024

    /** 路由路径前缀：`/v/<token>` */
    private const val PREFIX = "/v/"

    /** 一条已注册的路由：目标 URL + 转发时要带的 headers（如 Cookie/Authorization）。 */
    private data class Route(val url: String, val headers: Map<String, String>)

    /** 只读的一次请求（GET/HEAD 无 body）。 */
    private class Request(
        val method: String,
        val path: String,
        val headers: Map<String, String>,
    )

    private val routes = ConcurrentHashMap<String, Route>()

    private val lock = Any()

    @Volatile
    private var server: ServerSocket? = null

    @Volatile
    private var port: Int = 0

    /**
     * 确保代理已起（**幂等**）：首次绑 `127.0.0.1:0`（系统分配端口），
     * 起一条后台 accept 线程，每来一条连接再起一条处理线程。
     *
     * @return 监听端口（后续拼 `http://127.0.0.1:<port><path>` 用）。
     */
    fun ensureStarted(): Int {
        synchronized(lock) {
            server?.let { if (!it.isClosed) return port }
            val ss = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
            server = ss
            port = ss.localPort
            Thread({ acceptLoop(ss) }, "local-range-proxy-accept").apply {
                isDaemon = true
            }.start()
            Log.i(TAG, "stage=start port=$port")
            return port
        }
    }

    /**
     * 注册一条路由。
     *
     * @return 形如 `/v/<token>` 的**本地路径**（拼上 `http://127.0.0.1:<port>` 即数据源）。
     */
    fun route(url: String, headers: Map<String, String>): String {
        val token = UUID.randomUUID().toString().replace("-", "")
        routes[token] = Route(url, headers.toMap())
        // **不打印 header 值**（可能就是 `_sid` / Cookie）；只记个数与主机名。
        Log.i(TAG, "stage=route host=${hostOf(url)} headers=${headers.size}")
        return "$PREFIX$token"
    }

    /** 撤销路由（**必须**在抽帧结束时调用，否则 token + headers 泄漏）。 */
    fun unroute(path: String) {
        val token = tokenOf(path) ?: return
        if (routes.remove(token) != null) {
            Log.i(TAG, "stage=unroute")
        }
    }

    // ------------------------------------------------------------------ accept / 处理

    private fun acceptLoop(ss: ServerSocket) {
        while (true) {
            val socket = try {
                ss.accept()
            } catch (e: IOException) {
                // 代理被关（进程退出 / 显式 close）时正常退出；其它 IO 错继续等。
                if (ss.isClosed) return
                Log.w(TAG, "accept failed: ${e.javaClass.simpleName}: ${e.message}")
                continue
            }
            Thread({ handle(socket) }, "local-range-proxy-conn").apply {
                isDaemon = true
            }.start()
        }
    }

    /** 单连接处理：**任何异常都只记日志、关连接**，绝不让线程抛穿。 */
    private fun handle(socket: Socket) {
        try {
            socket.use { s ->
                s.soTimeout = READ_TIMEOUT_MS
                val request = readRequest(s) ?: return
                val route = tokenOf(request.path)?.let { routes[it] }
                if (route == null) {
                    Log.w(TAG, "stage=404 path=${request.path}")
                    writeStatusOnly(s, 404, "not routed")
                    return
                }
                forward(s, request, route)
            }
        } catch (e: Exception) {
            Log.w(TAG, "conn failed: ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /**
     * 把请求转给真 NAS，再把回包原样写回。
     *
     * * 显式 `requestMethod = "GET"`（平台可能发 HEAD，这里统一用 GET 取头部）；
     * * `Range` 与注册时的 headers 一并带上；
     * * 回包写 `HTTP/1.1 <code>` + `Content-Type`/`Content-Length`/`Content-Range`/
     *   `Accept-Ranges: bytes`/`Connection: close`，然后**按 Content-Length 流式**转发。
     */
    private fun forward(socket: Socket, request: Request, route: Route) {
        val opened = try {
            URL(route.url).openConnection()
        } catch (e: Exception) {
            Log.w(TAG, "stage=open-url err=${e.javaClass.simpleName}: ${e.message}")
            writeStatusOnly(socket, 502, "bad upstream url")
            return
        }
        // HttpsURLConnection 是 HttpURLConnection 的子类：https 目标拿到的就是它，
        // 因而**自动继承** MediaPlayerBridge.setTlsPolicy 装的全局放宽政策。
        if (opened !is HttpURLConnection) {
            Log.w(TAG, "stage=open-url err=not-http")
            writeStatusOnly(socket, 502, "unsupported upstream")
            return
        }
        // https 目标：拿到的就是 HttpsURLConnection（继承 setTlsPolicy 的全局放宽政策）；
        // http 目标（本机直连局域网 NAS）则退回普通 HttpURLConnection。
        val tls: HttpsURLConnection? = opened as? HttpsURLConnection
        val conn: HttpURLConnection = tls ?: opened
        // ★★ 第 42 轮真机修正：**不能只靠全局政策**。
        //   真机实测（logcat 逐字）：探针场景里 `MediaPlayerBridge.setTlsPolicy` 还没被调用
        //   （会话连接才装它）⇒ 代理这一跳直接死在
        //   `SSLPeerUnverifiedException: Hostname nas.example.com not verified`。
        //   注意那条错误的形态：**证书链是可信的**（真实通配证书 *.nas.example.com），
        //   只差"主机名与 CN/SAN 不一致" ⇒ 按连接**只放宽主机名**（不碰信任链），
        //   与 Dart 侧 TrustStore / §2.0.11 的口径一致：只对目标 host 放行，其余照旧。
        if (tls != null) {
            val targetHost = runCatching { URL(route.url).host }.getOrNull()
            if (!targetHost.isNullOrBlank()) {
                tls.hostnameVerifier = javax.net.ssl.HostnameVerifier { hostname, session ->
                    hostname == targetHost ||
                        HttpsURLConnection.getDefaultHostnameVerifier()
                            .verify(hostname, session)
                }
            }
        }
        try {
            conn.requestMethod = "GET"
            conn.connectTimeout = CONNECT_TIMEOUT_MS
            conn.readTimeout = READ_TIMEOUT_MS
            conn.instanceFollowRedirects = true
            request.headers["range"]?.takeIf { it.isNotBlank() }?.let {
                conn.setRequestProperty("Range", it)
            }
            // 注册时给的业务 headers（_sid / Cookie / Authorization…）。
            // 逐跳头（Host/Connection/Content-Length）由连接自己管，不转发。
            for ((k, v) in route.headers) {
                if (k.equals("host", true) || k.equals("connection", true) ||
                    k.equals("content-length", true) || k.equals("range", true)
                ) {
                    continue
                }
                runCatching { conn.setRequestProperty(k, v) }
            }
            // 不能带压缩：我们要按 Content-Length 原样转发，gzip 会让长度对不上。
            if (conn.getRequestProperty("Accept-Encoding") == null) {
                conn.setRequestProperty("Accept-Encoding", "identity")
            }

            val code = conn.responseCode
            val contentType = conn.contentType ?: guessContentType(route.url)
            val contentRange = conn.getHeaderField("Content-Range")
            val length = conn.contentLengthLong

            val out = BufferedOutputStream(socket.getOutputStream())
            val head = StringBuilder(256)
            head.append("HTTP/1.1 ").append(code).append(' ').append(reason(code)).append("\r\n")
            head.append("Content-Type: ").append(contentType).append("\r\n")
            if (length >= 0) head.append("Content-Length: ").append(length).append("\r\n")
            if (!contentRange.isNullOrBlank()) {
                head.append("Content-Range: ").append(contentRange).append("\r\n")
            }
            head.append("Accept-Ranges: bytes\r\n")
            head.append("Connection: close\r\n\r\n")
            out.write(head.toString().toByteArray(Charsets.US_ASCII))

            if (request.method != "HEAD") {
                val body: InputStream? =
                    if (code >= 400) conn.errorStream else runCatching { conn.inputStream }.getOrNull()
                if (body != null) {
                    body.use { copyStream(it, out, length) }
                }
            }
            out.flush()
        } catch (e: Exception) {
            // 客户端提前断开是常态（retriever 拿到要的字节就关）——只记，不抛。
            Log.w(TAG, "stage=forward err=${e.javaClass.simpleName}: ${e.message}")
        } finally {
            runCatching { conn.disconnect() }
        }
    }

    // ------------------------------------------------------------------ 工具

    /** 按 Content-Length 精确转发；长度未知（-1，比如 chunked）就一直转到 EOF。 */
    private fun copyStream(body: InputStream, out: OutputStream, length: Long) {
        val buf = ByteArray(COPY_BUFFER_BYTES)
        var remaining = length
        while (remaining != 0L) {
            val want = if (remaining > 0) minOf(buf.size.toLong(), remaining).toInt() else buf.size
            val n = body.read(buf, 0, want)
            if (n <= 0) return
            out.write(buf, 0, n)
            if (remaining > 0) remaining -= n
        }
    }

    /** 只读请求头（GET/HEAD 无 body，读到这里为止）。 */
    private fun readRequest(socket: Socket): Request? {
        val input = BufferedInputStream(socket.getInputStream())
        val raw = readHeaderBytes(input) ?: return null
        val lines = String(raw, Charsets.ISO_8859_1).split("\r\n")
        if (lines.isEmpty()) return null
        val parts = lines[0].split(" ")
        if (parts.size < 2) return null
        val headers = HashMap<String, String>()
        for (i in 1 until lines.size) {
            val line = lines[i]
            val idx = line.indexOf(':')
            if (idx <= 0) continue
            headers[line.substring(0, idx).trim().lowercase()] = line.substring(idx + 1).trim()
        }
        return Request(parts[0].uppercase(), parts[1], headers)
    }

    private fun readHeaderBytes(input: InputStream): ByteArray? {
        val buf = ByteArrayOutputStream(1024)
        var tail = 0
        while (true) {
            val b = input.read()
            if (b < 0) return if (buf.size() == 0) null else buf.toByteArray()
            buf.write(b)
            tail = ((tail shl 8) or b) and 0xFFFFFFFF.toInt()
            if (tail == 0x0D0A0D0A) break // \r\n\r\n
            if (buf.size() >= MAX_HEADER_BYTES) break
        }
        return buf.toByteArray()
    }

    private fun writeStatusOnly(socket: Socket, code: Int, text: String) {
        runCatching {
            val body = text.toByteArray(Charsets.UTF_8)
            val out = BufferedOutputStream(socket.getOutputStream())
            out.write(
                (
                    "HTTP/1.1 $code ${reason(code)}\r\n" +
                        "Content-Type: text/plain; charset=utf-8\r\n" +
                        "Content-Length: ${body.size}\r\n" +
                        "Connection: close\r\n\r\n"
                    ).toByteArray(Charsets.US_ASCII),
            )
            out.write(body)
            out.flush()
        }
    }

    /** `/v/<token>`（或去掉 query 的等价形式）→ token；不是本代理路径 → null。 */
    private fun tokenOf(path: String): String? {
        val clean = path.substringBefore('?')
        if (!clean.startsWith(PREFIX)) return null
        val token = clean.substring(PREFIX.length)
        if (token.isEmpty() || token.contains('/')) return null
        return token
    }

    private fun hostOf(url: String): String = runCatching {
        URL(url).host ?: ""
    }.getOrDefault("")

    /**
     * 缺省 Content-Type（上游没给时才用）：按 URL 路径扩展名猜。
     * （真 NAS 一般会自己给 `Content-Type`，这里只是最后一道兜底。）
     */
    private fun guessContentType(url: String): String {
        val path = runCatching { URL(url).path }.getOrNull() ?: url
        return when (path.substringAfterLast('.', "").lowercase()) {
            "mp4", "m4v" -> "video/mp4"
            "mov" -> "video/quicktime"
            "mkv" -> "video/x-matroska"
            "avi" -> "video/x-msvideo"
            "ts" -> "video/mp2t"
            "webm" -> "video/webm"
            else -> "application/octet-stream"
        }
    }

    private fun reason(code: Int): String = when (code) {
        200 -> "OK"
        206 -> "Partial Content"
        301 -> "Moved Permanently"
        302 -> "Found"
        304 -> "Not Modified"
        400 -> "Bad Request"
        403 -> "Forbidden"
        404 -> "Not Found"
        416 -> "Range Not Satisfiable"
        500 -> "Internal Server Error"
        502 -> "Bad Gateway"
        503 -> "Service Unavailable"
        else -> "Status"
    }
}
