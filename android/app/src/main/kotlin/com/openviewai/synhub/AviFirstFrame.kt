// 自研 **AVI/RIFF 首帧抽取**（第 269 轮；用户裁决「avi 如果你能自研抽取首帧也可以」）。
//
// ## 为什么必须自研容器解析
// 真机只读取证（`docs/device-verification.md §⑩.7`、`docs/thumbnail-apis.md §7`）：
//   * 设备平台 `MediaMetadataRetriever`/`MediaExtractor` **没有 RIFF/AVI 解析器**
//     （`dumpsys media.extractor` 的 12 个 extractor 里没有 AVI）⇒ `setDataSource`
//     必抛 `IllegalArgumentException`（`stage=open`）；
//   * **但解码器在**：同机有 `c2.android.mpeg4.decoder` / `OMX.google.mpeg4.decoder`
//     （`video/mp4v-es`，MPEG-4 Part 2，即 AVI 里的 `FMP4`/`XVID`/`DIVX` 家族）。
// ⇒ 缺的只是**容器解析**这一层。本文件就是自己写的那一层：
//   ① 走 RIFF/AVI 拿到视频 fourcc / 宽高 / fps / 帧数；
//   ② **顺序**走 `LIST movi` 的裸块（`00dc`/`##dc`…），收集最初的若干视频块；
//      **绝不依赖 `idx1`** —— 索引在文件尾（本样本 `@190,788,126`），而我们只下头部窗口，
//      索引天然不可达（AGENTS §2.0.17 ④：不许把"只读头部 N 字节"当事实，要给窗口外的
//      诚实失败理由）；
//   ③ 把裸 ES 喂给**平台** `MediaCodec`（零第三方编解码库），拿第一帧 Bitmap。
//
// ## 窗口/上限纪律（**不许为了缩略图下整个文件**）
// 输入永远是 Dart 侧已下好的**头部片段**（`video_frame_head`，上限 6 MiB）。
// 本文件再读入 ≤ [MAX_SCAN_BYTES]（8 MiB，永远 ≥ 那个窗口）做纯内存走查，
// 块数上限 [MAX_SCAN_CHUNKS]、交解码器的块数/字节上限 [MAX_ES_FRAMES]/[MAX_ES_BYTES]。
// 若关键帧不在给到的片段里 ⇒ `stage=avi-keyframe` + `reason=keyframe-outside-window:*`，
// **绝不**要求下载更多字节（失败会进 Dart 侧负缓存，不会反复重试）。
//
// ## 与桥的分工
// `VideoFrameBridge.extractDetailed` 在 `stage=open` 且容器是 `riff/avi` 时**才**走这里
// （**fallback**：MP4/MKV 等平台能开的文件一行都不会进本文件，快路径零影响）。
// 本类只回 **Bitmap**；缩放 + JPEG 编码仍由桥里**既有**的那段代码做 ⇒ Dart 侧契约不变。
//
// ## 四个新 stage（logcat 可查，见 `VideoFrameBridge` 的 `stage=` 家族）
//   * `avi-parse`    —— RIFF/AVI 头解不出（不是 AVI / 没有 `movi` / 没有视频轨 / 脏 size）
//   * `avi-keyframe` —— 头解出来了，但**关键帧不在给到的头部窗口里**（附扫了多少块）
//   * `avi-codec`    —— 容器解出来了，但 fourcc 不认识 / 本机没有对应解码器
//   * `avi-decode`   —— 解码器在，但喂进去没出帧（超时 / EOS / YUV 格式不支持）
//   * `avi-ok`       —— 成功（`via=avi-fallback`）
package com.openviewai.synhub

import android.graphics.Bitmap
import android.media.Image
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.SystemClock
import android.util.Log
import java.io.File

/**
 * AVI 首帧抽取器：**纯容器解析**（RIFF 走查）+ **平台解码**（MediaCodec）。
 *
 * 无任何第三方依赖；不申请权限；不碰网络（只吃本地路径）。
 */
internal object AviFirstFrame {

    /** 与 `VideoFrameBridge` 共用 tag ⇒ `adb logcat -s VideoFrameBridge` 一条线看全。 */
    private const val TAG = "VideoFrameBridge"

    // ------------------------------------------------------------ stage（与 Dart 逐字对应）
    const val STAGE_PARSE = "avi-parse"
    const val STAGE_KEYFRAME = "avi-keyframe"
    const val STAGE_CODEC = "avi-codec"
    const val STAGE_DECODE = "avi-decode"
    const val STAGE_OK = "avi-ok"

    /** 纯内存走查读入上限：8 MiB（永远 ≥ Dart 侧 6 MiB 头部窗口）。 */
    private const val MAX_SCAN_BYTES = 8 * 1024 * 1024

    /** 走查块数上限（脏 size 会造出死循环/爆内存，必须封顶）。 */
    private const val MAX_SCAN_CHUNKS = 4096

    /** 交给解码器的视频块数上限（够出第一帧就行，别把整段 GOP 灌进去）。 */
    private const val MAX_ES_FRAMES = 64

    /** 交给解码器的裸 ES 字节上限（2 MiB；真样本第一块才 902 B）。 */
    private const val MAX_ES_BYTES = 2 * 1024 * 1024

    /** 解码超时：软件解一帧 320×240 是毫秒级；4 s 还没出帧就是真失败。 */
    private const val DECODE_TIMEOUT_MS = 4000L

    /**
     * ★ 第 42 轮：**黑帧阈值**。
     */
    private const val LUMA_MIN = 12

    // `MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar/SemiPlanar` 在
    // 较新 SDK 里标了 deprecated（推荐 flexible），但我们手工回退路径**就是要**认这两个
    // 具体布局 ⇒ 用字面量，避免 deprecation 噪声。值与平台常量逐字一致（19/21）。
    private const val YUV420_PLANAR = 19
    private const val YUV420_SEMI_PLANAR = 21

    // ------------------------------------------------------------ 数据结构

    /** `movi` 里的一个视频块（[payloadOffset] 是**负载**起点，不含 8 字节块头）。 */
    private class VideoChunk(val payloadOffset: Int, val size: Int)

    /**
     * 一次 RIFF/AVI 走查的结果。
     *
     * [failStage] 为空 = 走查成功（此时 [chunks] 非空、[fourcc] 已给出）；
     * 非空 = 失败，[failReason] 是**机器可读**的原因（日志/诊断用，不是给用户的中文）。
     */
    private class AviWalk(
        val fourcc: String,
        val width: Int,
        val height: Int,
        val fps: Double,
        val frameCount: Int,
        val moviOffset: Int,
        val moviPayload: Int,
        val firstChunkOffset: Int,
        val firstChunkSize: Int,
        val scannedChunks: Int,
        val videoChunks: Int,
        val audioChunks: Int,
        val chunks: List<VideoChunk>,
        val esBytes: Int,
        val failStage: String,
        val failReason: String,
    )

    /** 一次自研抽取的结果：**要么有 Bitmap，要么有 stage + 原因**。 */
    class Result(
        /** 成功时的第一帧（**未缩放、未编码**；编码仍由桥里既有那段做） */
        val bitmap: Bitmap?,
        val stage: String,
        val reason: String,
        val fourcc: String,
        val mime: String,
        val width: Int,
        val height: Int,
        val fps: Double,
        val frameCount: Int,
        val moviOffset: Int,
        val chunkOffset: Int,
        val chunkSize: Int,
        val scannedChunks: Int,
        val videoChunks: Int,
        val esFrames: Int,
        val esBytes: Int,
    ) {
        val ok: Boolean get() = stage == STAGE_OK
    }

    /**
     * fourcc → 平台解码器 MIME（**唯一权威表**；Dart 侧 `aviFourccMime` 是它的离线镜像）。
     *
     * 只映射**有把握**的：不认识就回空串 ⇒ 调用方给 `avi-codec` +
     * `fourcc-unsupported:<fourcc>`，**绝不许**猜一个 MIME 出来。
     */
    fun mimeForFourcc(raw: String): String {
        val f = raw.trim().uppercase()
        return when (f) {
            // MPEG-4 Part 2（DivX/XviD 家族）—— 真机有 c2.android.mpeg4.decoder
            "FMP4", "XVID", "DIVX", "DX50", "MP4V", "MP4S", "M4S2", "3IV2" ->
                "video/mp4v-es"
            // Motion JPEG
            "MJPG", "MJPEG" -> "video/mjpeg"
            // H.264 / AVC（AVI 里一般是 Annex-B，首块自带 SPS/PPS）
            "H264", "X264", "AVC1", "H26L", "DAVC" -> "video/avc"
            // H.265 / HEVC
            "H265", "X265", "HEVC", "HVC1", "HEV1" -> "video/hevc"
            else -> ""
        }
    }

    // ------------------------------------------------------------ 入口

    /**
     * 从本地片段里自研抽第一帧。
     *
     * @param src      Dart 侧下好的本地头部片段（≤ 6 MiB）
     * @param maxWidth 目标宽度（**只用于日志**；缩放由桥做）
     */
    fun extractFrame(src: File, maxWidth: Int): Result {
        val bytes = readHead(src)
        if (bytes == null || bytes.size < 12) {
            Log.w(
                TAG,
                "stage=$STAGE_PARSE path=${src.name} size=${src.length()} " +
                    "reason=read-failed-or-too-short readBytes=${bytes?.size ?: 0}",
            )
            return failure(STAGE_PARSE, "read-failed-or-too-short")
        }
        val walk = walk(bytes)
        Log.i(
            TAG,
            "stage=$STAGE_PARSE path=${src.name} size=${src.length()} " +
                "fourcc=${walk.fourcc} w=${walk.width} h=${walk.height} " +
                "fps=${fmtFps(walk.fps)} frames=${walk.frameCount} " +
                "movi=${walk.moviOffset} payload=${walk.moviPayload} " +
                "chunk=${walk.firstChunkOffset}/${walk.firstChunkSize} " +
                "scanned=${walk.scannedChunks} vchunks=${walk.videoChunks} " +
                "achunks=${walk.audioChunks} esBytes=${walk.esBytes} " +
                "fail=${walk.failStage.ifEmpty { "none" }} reason=${walk.failReason}",
        )
        if (walk.failStage.isNotEmpty()) {
            Log.w(
                TAG,
                "stage=${walk.failStage} path=${src.name} fourcc=${walk.fourcc} " +
                    "scanned=${walk.scannedChunks} reason=${walk.failReason}",
            )
            return failure(walk.failStage, walk.failReason, walk)
        }
        if (walk.width <= 0 || walk.height <= 0) {
            // MediaFormat.createVideoFormat 只吃正数；尺寸读不到就不猜（honest）。
            Log.w(
                TAG,
                "stage=$STAGE_PARSE path=${src.name} fourcc=${walk.fourcc} " +
                    "reason=missing-dimensions w=${walk.width} h=${walk.height}",
            )
            return failure(STAGE_PARSE, "missing-dimensions", walk)
        }

        val mime = mimeForFourcc(walk.fourcc)
        if (mime.isEmpty()) {
            Log.w(
                TAG,
                "stage=$STAGE_CODEC path=${src.name} fourcc=${walk.fourcc} " +
                    "reason=fourcc-unsupported:${walk.fourcc}",
            )
            return failure(STAGE_CODEC, "fourcc-unsupported:${walk.fourcc}", walk)
        }

        // 解码器存在性：`createDecoderByType` 在"本机没有这个 MIME 的解码器"时抛
        // IOException/IllegalArgumentException —— 那正是"容器解出来了，但**编码**不支持"，
        // 与"容器不支持"是两件事，stage 也分成两个。
        val decoded = try {
            decodeFirstFrame(bytes, walk, mime)
        } catch (e: Exception) {
            Log.w(
                TAG,
                "stage=$STAGE_CODEC path=${src.name} fourcc=${walk.fourcc} mime=$mime " +
                    "reason=decoder-unavailable:${e.javaClass.simpleName}",
            )
            return failure(
                STAGE_CODEC, "decoder-unavailable:$mime", walk, mime = mime,
            )
        }
        val frame = decoded.first
        if (frame == null) {
            Log.w(
                TAG,
                "stage=$STAGE_DECODE path=${src.name} fourcc=${walk.fourcc} mime=$mime " +
                    "w=${walk.width} h=${walk.height} esFrames=${walk.chunks.size} " +
                    "esBytes=${walk.esBytes} reason=${decoded.second}",
            )
            return failure(STAGE_DECODE, decoded.second, walk, mime = mime)
        }
        // ★ black frame check
        val luma = VideoFrameBridge.averageLuma(frame)
        if (luma < LUMA_MIN) {
            frame.recycle()
            Log.w(
                TAG,
                "stage=$STAGE_DECODE path=${src.name} fourcc=${walk.fourcc} mime=$mime " +
                    "w=${walk.width} h=${walk.height} luma=$luma " +
                    "reason=all-black-frame:luma=$luma",
            )
            return failure(
                STAGE_DECODE, "all-black-frame:luma=$luma", walk, mime = mime,
            )
        }
        Log.i(
            TAG,
            "stage=$STAGE_OK path=${src.name} via=avi-fallback fourcc=${walk.fourcc} " +
                "mime=$mime ${frame.width}x${frame.height} maxWidth=$maxWidth " +
                "luma=$luma esFrames=${walk.chunks.size} esBytes=${walk.esBytes}",
        )
        return Result(
            bitmap = frame,
            stage = STAGE_OK,
            reason = "",
            fourcc = walk.fourcc,
            mime = mime,
            width = frame.width,
            height = frame.height,
            fps = walk.fps,
            frameCount = walk.frameCount,
            moviOffset = walk.moviOffset,
            chunkOffset = walk.firstChunkOffset,
            chunkSize = walk.firstChunkSize,
            scannedChunks = walk.scannedChunks,
            videoChunks = walk.videoChunks,
            esFrames = walk.chunks.size,
            esBytes = walk.esBytes,
        )
    }

    private fun failure(
        stage: String,
        reason: String,
        walk: AviWalk? = null,
        mime: String = "",
    ): Result = Result(
        bitmap = null,
        stage = stage,
        reason = reason,
        fourcc = walk?.fourcc ?: "",
        mime = mime,
        width = walk?.width ?: 0,
        height = walk?.height ?: 0,
        fps = walk?.fps ?: 0.0,
        frameCount = walk?.frameCount ?: 0,
        moviOffset = walk?.moviOffset ?: -1,
        chunkOffset = walk?.firstChunkOffset ?: -1,
        chunkSize = walk?.firstChunkSize ?: 0,
        scannedChunks = walk?.scannedChunks ?: 0,
        videoChunks = walk?.videoChunks ?: 0,
        esFrames = walk?.chunks?.size ?: 0,
        esBytes = walk?.esBytes ?: 0,
    )

    // ------------------------------------------------------------ 读入（有界）

    /**
     * 读入 ≤ [MAX_SCAN_BYTES]。
     *
     * ⚠️ **不要用 `InputStream.readNBytes`**：Java 9 API，Android 到 API 33 才有
     * （本仓 minSdk 24）⇒ 手写有界读取（与 `VideoFrameBridge.probeContainer` 同款）。
     */
    private fun readHead(src: File): ByteArray? = runCatching {
        val cap = minOf(src.length(), MAX_SCAN_BYTES.toLong()).toInt()
        if (cap <= 0) return@runCatching null
        val buf = ByteArray(cap)
        var n = 0
        src.inputStream().use { ins ->
            while (n < cap) {
                val r = ins.read(buf, n, cap - n)
                if (r <= 0) break
                n += r
            }
        }
        if (n == cap) buf else buf.copyOf(n)
    }.getOrNull()

    // ------------------------------------------------------------ RIFF/AVI 走查

    /**
     * **顺序**走 RIFF：`RIFF/AVI ` → `LIST hdrl`（`avih` + 视频 `LIST strl`）→
     * `LIST movi`（裸块，含一层 `LIST rec `）。
     *
     * 只读内存里的 [b]；越界一律当"窗口不够"（`avi-keyframe`），
     * **绝不**按 `RIFF` 声明的 size 去信任文件长度。
     */
    private fun walk(b: ByteArray): AviWalk {
        fun fail(stage: String, reason: String): AviWalk = AviWalk(
            fourcc = "", width = 0, height = 0, fps = 0.0, frameCount = 0,
            moviOffset = -1, moviPayload = -1, firstChunkOffset = -1,
            firstChunkSize = 0, scannedChunks = 0, videoChunks = 0,
            audioChunks = 0, chunks = emptyList(), esBytes = 0,
            failStage = stage, failReason = reason,
        )
        if (b.ascii(0) != "RIFF") return fail(STAGE_PARSE, "not-riff")
        if (b.ascii(8) != "AVI ") return fail(STAGE_PARSE, "riff-not-avi")

        var fourcc = ""
        var width = 0
        var height = 0
        var fps = 0.0
        var frames = 0
        var moviOffset = -1
        var moviPayload = -1

        // 第一遍：hdrl 信息 + movi 起点。遇到 movi 就停（后面按块走）。
        var off = 12
        var guard = 0
        while (off + 8 <= b.size && guard++ < MAX_SCAN_CHUNKS) {
            val id = b.ascii(off)
            val size = le32(b, off + 4)
            if (size < 0) return fail(STAGE_PARSE, "bad-chunk-size")
            if (id == "LIST" && off + 12 <= b.size) {
                val form = b.ascii(off + 8)
                if (form == "hdrl") {
                    val h = parseHdrl(b, off + 12, minOf(off + 8 + size, b.size))
                    if (h.type == "vids") {
                        fourcc = h.fourcc
                        width = if (h.biWidth > 0) h.biWidth else h.width
                        height = if (h.biHeight > 0) h.biHeight else h.height
                        fps = h.fps
                        frames = h.frameCount
                    }
                } else if (form == "movi") {
                    moviOffset = off
                    moviPayload = off + 12
                    break
                }
            }
            val step = 8L + size + (size and 1)
            if (step <= 8) return fail(STAGE_PARSE, "chunk-loop-guard")
            off += step.toInt()
        }
        if (moviPayload < 0) return fail(STAGE_PARSE, "no-movi-in-window")
        if (fourcc.isEmpty()) {
            return fail(
                STAGE_PARSE,
                if (width == 0 && height == 0) "no-video-stream" else "no-video-fourcc",
            )
        }

        // 第二遍：从 movi 载荷顺序扫块（`LIST rec ` 递归一层）。
        val chunks = ArrayList<VideoChunk>()
        var videoChunks = 0
        var audioChunks = 0
        var scanned = 0
        var esBytes = 0

        fun scan(from: Int, to: Int, depth: Int) {
            var p = from
            var g = 0
            while (p + 8 <= to && g++ < MAX_SCAN_CHUNKS) {
                scanned++
                val id = b.ascii(p)
                val size = le32(b, p + 4)
                // 块体越过窗口 ⇒ 窗口到此为止（不是错误，是"我们只下了头部"）。
                if (size < 0 || p + 8L + size > b.size) return
                if (id == "LIST" && depth < 2 && p + 12 <= b.size &&
                    b.ascii(p + 8) == "rec "
                ) {
                    scan(p + 12, minOf(p + 8 + size, to), depth + 1)
                } else if (isVideoChunk(id)) {
                    videoChunks++
                    if (chunks.size < MAX_ES_FRAMES && esBytes + size <= MAX_ES_BYTES) {
                        chunks.add(VideoChunk(p + 8, size))
                        esBytes += size
                    }
                } else if (isAudioChunk(id)) {
                    audioChunks++
                }
                val step = 8L + size + (size and 1)
                if (step <= 8) return
                p += step.toInt()
            }
        }
        scan(moviPayload, b.size, 0)

        if (chunks.isEmpty()) {
            // 有 movi、有视频轨，但窗口里一个视频块都没有 ⇒ 关键帧在窗口外。
            return AviWalk(
                fourcc = fourcc, width = width, height = height, fps = fps,
                frameCount = frames, moviOffset = moviOffset, moviPayload = moviPayload,
                firstChunkOffset = -1, firstChunkSize = 0, scannedChunks = scanned,
                videoChunks = videoChunks, audioChunks = audioChunks,
                chunks = emptyList(), esBytes = 0,
                failStage = STAGE_KEYFRAME,
                failReason = "keyframe-outside-window:scanned=$scanned" +
                    ":windowBytes=${b.size}:movi=$moviPayload",
            )
        }
        val first = chunks[0]
        return AviWalk(
            fourcc = fourcc, width = width, height = height, fps = fps,
            frameCount = frames, moviOffset = moviOffset, moviPayload = moviPayload,
            firstChunkOffset = first.payloadOffset - 8, firstChunkSize = first.size,
            scannedChunks = scanned, videoChunks = videoChunks,
            audioChunks = audioChunks, chunks = chunks, esBytes = esBytes,
            failStage = "", failReason = "",
        )
    }

    /** `hdrl` 的解析结果（`avih` + 视频 `strl`）。 */
    private class HdrlInfo(
        val type: String,
        val fourcc: String,
        val width: Int,
        val height: Int,
        val biWidth: Int,
        val biHeight: Int,
        val fps: Double,
        val frameCount: Int,
    )

    /**
     * 解 `hdrl` 体内：`avih`（帧数/宽高）+ 每条 `LIST strl`（`strh`/`strf`）。
     *
     * 视频 fourcc：**`strf.biCompression` 优先**（BITMAPINFOHEADER 偏移 +16），
     * 拿不到再回退 `strh.fccHandler` —— 与 `VideoFrameBridge.oneStrlVideoFourcc` 同口径。
     */
    private fun parseHdrl(b: ByteArray, from: Int, to: Int): HdrlInfo {
        var p = from
        var guard = 0
        var type = ""
        var fourcc = ""
        var handler = ""
        var biWidth = 0
        var biHeight = 0
        var rawW = 0
        var rawH = 0
        var fps = 0.0
        var frames = 0
        while (p + 8 <= to && guard++ < MAX_SCAN_CHUNKS) {
            val id = b.ascii(p)
            val size = le32(b, p + 4)
            if (size < 0) break
            if (id == "avih" && size >= 40 && p + 8 + 40 <= b.size) {
                frames = le32(b, p + 8 + 16)
                rawW = le32(b, p + 8 + 32)
                rawH = le32(b, p + 8 + 36)
            } else if (id == "LIST" && size >= 4 && p + 12 <= b.size &&
                b.ascii(p + 8) == "strl"
            ) {
                val inner = parseStrl(b, p + 12, minOf(p + 8 + size, to))
                if (inner.type == "vids" && type != "vids") {
                    type = "vids"
                    handler = inner.handler
                    // `strf.biCompression` 优先；它是非可打印的十六进制时才回退 fccHandler。
                    fourcc = if (inner.compression.isNotEmpty() &&
                        !inner.compression.startsWith("0x")
                    ) {
                        inner.compression
                    } else {
                        inner.handler
                    }
                    biWidth = inner.biWidth
                    biHeight = inner.biHeight
                    fps = inner.fps
                }
            }
            val step = 8L + size + (size and 1)
            if (step <= 8) break
            p += step.toInt()
        }
        if (type == "vids" && fourcc.isEmpty()) fourcc = handler
        return HdrlInfo(
            type = type,
            fourcc = fourcc,
            width = rawW,
            height = rawH,
            biWidth = biWidth,
            biHeight = biHeight,
            fps = fps,
            frameCount = frames,
        )
    }

    private class StrlInfo(
        val type: String,
        val handler: String,
        val compression: String,
        val biWidth: Int,
        val biHeight: Int,
        val fps: Double,
    )

    private fun parseStrl(b: ByteArray, from: Int, to: Int): StrlInfo {
        var p = from
        var guard = 0
        var type = ""
        var handler = ""
        var compression = ""
        var biWidth = 0
        var biHeight = 0
        var scale = 0
        var rate = 0
        while (p + 8 <= to && guard++ < MAX_SCAN_CHUNKS) {
            val id = b.ascii(p)
            val size = le32(b, p + 4)
            if (size < 0) break
            if (id == "strh" && size >= 8 && p + 8 + 8 <= b.size) {
                type = b.ascii(p + 8)
                handler = fourccOrHex(b, p + 12)
                if (p + 8 + 28 <= b.size) {
                    scale = le32(b, p + 8 + 20)
                    rate = le32(b, p + 8 + 24)
                }
            } else if (id == "strf" && size >= 20 && p + 8 + 20 <= b.size) {
                biWidth = le32(b, p + 8 + 4)
                biHeight = le32(b, p + 8 + 8)
                compression = fourccOrHex(b, p + 8 + 16)
            }
            val step = 8L + size + (size and 1)
            if (step <= 8) break
            p += step.toInt()
        }
        val fps = if (scale > 0 && rate > 0) rate.toDouble() / scale else 0.0
        return StrlInfo(type, handler, compression, biWidth, biHeight, fps)
    }

    // ------------------------------------------------------------ MediaCodec 解码

    /**
     * 把裸 ES 块逐个喂给平台解码器，返回**第一帧**。
     *
     * 返回 `(bitmap, reason)`：bitmap 为 null 时 reason 是机器可读的失败原因。
     * 每个 `movi` 视频块 = 一个访问单元（Annex-B / MPEG-4 Part 2 的 VOP 边界），
     * 所以**逐块 queue** 而不是拼成一个大 buffer（拼接会把 VOP 边界信息丢掉）。
     */
    private fun decodeFirstFrame(
        b: ByteArray,
        walk: AviWalk,
        mime: String,
    ): Pair<Bitmap?, String> {
        val codec = MediaCodec.createDecoderByType(mime)
        val format = MediaFormat.createVideoFormat(mime, walk.width, walk.height)
        val info = MediaCodec.BufferInfo()
        val deadline = SystemClock.elapsedRealtime() + DECODE_TIMEOUT_MS
        val frameUs = if (walk.fps > 0) (1_000_000.0 / walk.fps).toLong() else 66_666L
        var queued = 0
        var inputDone = false
        var colorFormat = 0
        var reason = "no-output"
        var result: Bitmap? = null
        try {
            codec.configure(format, null, null, 0)
            codec.start()
            while (SystemClock.elapsedRealtime() < deadline) {
                // ① 供料：一块一块喂；喂完送 EOS（flush 解码器缓存）
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) {
                        if (queued < walk.chunks.size) {
                            val buf = codec.getInputBuffer(inIdx)
                            val c = walk.chunks[queued]
                            if (buf == null) {
                                reason = "no-input-buffer"
                                break
                            }
                            buf.clear()
                            val n = minOf(c.size, buf.capacity())
                            buf.put(b, c.payloadOffset, n)
                            codec.queueInputBuffer(inIdx, 0, n, queued * frameUs, 0)
                            queued++
                        } else {
                            codec.queueInputBuffer(
                                inIdx, 0, 0, queued * frameUs,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputDone = true
                        }
                    }
                }
                // ② 收帧
                val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                when {
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val fmt = codec.outputFormat
                        colorFormat = if (fmt.containsKey(MediaFormat.KEY_COLOR_FORMAT)) {
                            runCatching { fmt.getInteger(MediaFormat.KEY_COLOR_FORMAT) }
                                .getOrDefault(0)
                        } else {
                            0
                        }
                    }
                    outIdx >= 0 -> {
                        if (info.size > 0) {
                            val frame = outputBitmap(codec, outIdx)
                            if (frame != null) {
                                result = frame
                                codec.releaseOutputBuffer(outIdx, false)
                                break
                            }
                            reason = "yuv-convert-failed:colorFormat=$colorFormat"
                        }
                        codec.releaseOutputBuffer(outIdx, false)
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            reason = if (queued == 0) "no-video-chunk" else "eos-no-frame"
                            break
                        }
                    }
                    outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        if (inputDone && queued == 0) {
                            reason = "no-video-chunk"
                            break
                        }
                    }
                }
            }
        } finally {
            runCatching { codec.stop() }
            runCatching { codec.release() }
        }
        if (result == null && SystemClock.elapsedRealtime() >= deadline) {
            return null to "decode-timeout:queued=$queued"
        }
        return result to reason
    }

    /**
     * 解码输出 → Bitmap。
     *
     * 优先 `getOutputImage`（`COLOR_FormatYUV420Flexible`，带 rowStride/pixelStride，
     * 能正确处理对齐填充）；它不可用（非 flexible，`getOutputImage` 会抛）时按
     * `COLOR_FormatYUV420Planar(19)` / `COLOR_FormatYUV420SemiPlanar(21)` 手工解。
     * 两种都失败 ⇒ 回 null（调用方给 `yuv-convert-failed`，**不编图**）。
     */
    private fun outputBitmap(codec: MediaCodec, outIdx: Int): Bitmap? {
        val image = try {
            codec.getOutputImage(outIdx)
        } catch (_: Exception) {
            null
        }
        if (image != null) {
            return try {
                imageToBitmap(image)
            } finally {
                image.close()
            }
        }
        return rawBufferToBitmap(codec, outIdx)
    }

    /** `Image`（flexible/planar/semiplanar）→ ARGB Bitmap（BT.601 limited range）。 */
    private fun imageToBitmap(image: Image): Bitmap? {
        val w = image.width
        val h = image.height
        if (w <= 0 || h <= 0) return null
        val planes = image.planes
        if (planes.size < 3) return null
        val y = planes[0]
        val u = planes[1]
        val v = planes[2]
        val yBuf = y.buffer
        val uBuf = u.buffer
        val vBuf = v.buffer
        val pixels = IntArray(w * h)
        for (j in 0 until h) {
            val yRow = j * y.rowStride
            val uvRow = j / 2
            val uRow = uvRow * u.rowStride
            val vRow = uvRow * v.rowStride
            for (i in 0 until w) {
                val yv = yBuf.get(yRow + i * y.pixelStride).toInt() and 0xFF
                val uvCol = (i / 2) * u.pixelStride
                val uv = uBuf.get(uRow + uvCol).toInt() and 0xFF
                val vv = vBuf.get(vRow + uvCol).toInt() and 0xFF
                pixels[j * w + i] = yuvToArgb(yv, uv, vv)
            }
        }
        return Bitmap.createBitmap(pixels, w, h, Bitmap.Config.ARGB_8888)
    }

    /** 非 flexible 输出的手工回退（planar 19 / semiplanar 21）。 */
    private fun rawBufferToBitmap(codec: MediaCodec, outIdx: Int): Bitmap? {
        val buf = try {
            codec.getOutputBuffer(outIdx)
        } catch (_: Exception) {
            null
        } ?: return null
        val fmt = codec.outputFormat
        val color = if (fmt.containsKey(MediaFormat.KEY_COLOR_FORMAT)) {
            runCatching { fmt.getInteger(MediaFormat.KEY_COLOR_FORMAT) }.getOrDefault(0)
        } else {
            0
        }
        val w = if (fmt.containsKey(MediaFormat.KEY_WIDTH)) {
            runCatching { fmt.getInteger(MediaFormat.KEY_WIDTH) }.getOrDefault(0)
        } else {
            0
        }
        val h = if (fmt.containsKey(MediaFormat.KEY_HEIGHT)) {
            runCatching { fmt.getInteger(MediaFormat.KEY_HEIGHT) }.getOrDefault(0)
        } else {
            0
        }
        if (w <= 0 || h <= 0) return null
        val pos = buf.position()
        val pixels = IntArray(w * h)
        when (color) {
            // COLOR_FormatYUV420Planar = 19：Y(w*h) U(w*h/4) V(w*h/4)
            YUV420_PLANAR -> {
                val frame = w * h
                val quarter = frame / 4
                if (buf.limit() - pos < frame + 2 * quarter) return null
                for (j in 0 until h) {
                    for (i in 0 until w) {
                        val yv = buf.get(pos + j * w + i).toInt() and 0xFF
                        val uv = buf.get(pos + frame + (j / 2) * (w / 2) + i / 2)
                            .toInt() and 0xFF
                        val vv = buf.get(
                            pos + frame + quarter + (j / 2) * (w / 2) + i / 2,
                        ).toInt() and 0xFF
                        pixels[j * w + i] = yuvToArgb(yv, uv, vv)
                    }
                }
            }
            // COLOR_FormatYUV420SemiPlanar = 21：Y + 交错 UV
            YUV420_SEMI_PLANAR -> {
                val frame = w * h
                if (buf.limit() - pos < frame + frame / 2) return null
                for (j in 0 until h) {
                    for (i in 0 until w) {
                        val yv = buf.get(pos + j * w + i).toInt() and 0xFF
                        val uvOff = pos + frame + (j / 2) * w + (i / 2) * 2
                        val uv = buf.get(uvOff).toInt() and 0xFF
                        val vv = buf.get(uvOff + 1).toInt() and 0xFF
                        pixels[j * w + i] = yuvToArgb(yv, uv, vv)
                    }
                }
            }
            else -> return null
        }
        return Bitmap.createBitmap(pixels, w, h, Bitmap.Config.ARGB_8888)
    }

    /** BT.601 limited-range YUV → ARGB（整数近似，够缩略图）。 */
    private fun yuvToArgb(y: Int, u: Int, v: Int): Int {
        val c = (y - 16).coerceAtLeast(0)
        val d = u - 128
        val e = v - 128
        val r = ((298 * c + 409 * e + 128) shr 8).coerceIn(0, 255)
        val g = ((298 * c - 100 * d - 208 * e + 128) shr 8).coerceIn(0, 255)
        val b = ((298 * c + 516 * d + 128) shr 8).coerceIn(0, 255)
        return (0xFF shl 24) or (r shl 16) or (g shl 8) or b
    }

    // ------------------------------------------------------------ 小工具

    /** `##dc` / `##db` = 视频块（`##` 是流号）。 */
    private fun isVideoChunk(id: String): Boolean =
        id.length == 4 && id[0].isDigit() && id[1].isDigit() &&
            id[2] == 'd' && (id[3] == 'c' || id[3] == 'b')

    /** `##wb` / `##wc` = 音频块。 */
    private fun isAudioChunk(id: String): Boolean =
        id.length == 4 && id[0].isDigit() && id[1].isDigit() &&
            id[2] == 'w' && (id[3] == 'b' || id[3] == 'c')

    /** 4 字节 fourcc：全可打印就给原串，否则 `0x%08X`（音频 `0x00000001` 那种）。 */
    private fun fourccOrHex(b: ByteArray, off: Int): String {
        if (off + 4 > b.size) return ""
        var printable = true
        for (i in off until off + 4) {
            val c = b[i].toInt() and 0xFF
            if (c < 0x20 || c > 0x7E) printable = false
        }
        if (printable) return b.ascii(off)
        return String.format("0x%08X", le32(b, off))
    }

    private fun le32(b: ByteArray, off: Int): Int {
        if (off + 4 > b.size) return -1
        return (b[off].toInt() and 0xFF) or
            ((b[off + 1].toInt() and 0xFF) shl 8) or
            ((b[off + 2].toInt() and 0xFF) shl 16) or
            ((b[off + 3].toInt() and 0xFF) shl 24)
    }

    private fun ByteArray.ascii(off: Int): String {
        if (off + 4 > size) return ""
        return String(this, off, 4, Charsets.US_ASCII)
    }

    private fun fmtFps(fps: Double): String =
        if (fps == fps.toLong().toDouble()) {
            fps.toLong().toString()
        } else {
            String.format("%.3f", fps)
        }
}
