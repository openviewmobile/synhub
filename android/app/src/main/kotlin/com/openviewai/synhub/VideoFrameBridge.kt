// 视频「首帧」抽帧桥（自研兜底，第 261 轮）。
//
// ## 为什么需要它
// 真 NAS 只读实测（docs/thumbnail-apis.md）：
//   * `SYNO.FileStation.Thumb:get`（v1/v2/v3）**只对图片出图**；对视频
//     （`/home/video/*.mp4`、`/home/Photos/手机备份/SVID_*.mp4`）一律
//     `HTTP 404` + 11939B HTML（两个不同视频的 404 响应体 sha256 相同
//     ⇒ 既不是真帧、也不是占位图）；
//   * `SYNO.SynologyDrive.Files:get_thumbnail`、`SYNO.Office.Video.Thumb`
//     同样出不了视频帧；Photos 侧唯一那条视频的缩略状态是 `ame_defect`；
//   * 本机没有 VideoStation（`SYNO.API.Info` 1047 个 API 里没有
//     `SYNO.VideoStation.*` / `SYNO.DSVideo.*`）⇒ **服务端没有视频缩略图**。
// 用户裁决：「服务端优先，失败再自研抽帧」⇒ 这里就是那个"自研抽帧"的**薄桥**。
//
// ## 边界（**照任务书，不许越界**）
//   * **不申请任何新权限**（抽帧不需要权限，尤其**不碰 `RECORD_AUDIO`**）；
//   * **不新建 MethodChannel 插件工程**：与 `MediaStoreBridge` /
//     `MediaPlayerBridge` 同款式 —— 单文件 object + `MainActivity` 里注册；
//   * **网络不交给原生**：Dart 侧用 App 自己的 Dio/传输层（已按 §2.0.11
//     放宽自签证书）下载文件头部若干 MB 到**临时文件**，这里只吃**本地路径**；
//   * 抽帧用 `android.media.MediaMetadataRetriever`：
//     API 27+ 走 `getScaledFrameAtTime(0, OPTION_CLOSEST_SYNC, w, h)`（直接出小图，
//     省一次整帧分配）；API < 27 回退 `getFrameAtTime` + `Bitmap.createScaledBitmap`
//     （本仓 `minSdk = flutter.minSdkVersion = 24`，所以这条回退是**真需要**的）。
//
// ## Dart 侧契约（**由 `lib/src/core/media/video_frame_bridge.dart` 固定**）
//   * 通道 `synhub/video_frame`
//   * 方法 `isSupported` → **Bool**（本机能不能抽帧）
//   * 方法 `extractFrame`，入参：
//       - `path`   String，**本地文件绝对路径**（Dart 已下好的头部临时文件）
//       - `atMs`   Int/Long，取帧时间戳（默认 0 = 第一帧）
//       - `maxWidth` Int，目标宽度上限（默认 320）
//     返回 **Map?**：
//       - `bytes`    ByteArray —— **实际编码是 JPEG**（`Bitmap.compress(JPEG, 85)`），
//                    不是 PNG；`mime` 字段逐字写 `image/jpeg`
//       - `encoding` String，本实现恒为 `"jpeg"`（**返回编码说明就在这一行**）
//       - `mime`     String，`"image/jpeg"`
//       - `width`/`height` Int，实际像素尺寸
//       null = 抽不出来（容器解不了 / 没有视频轨 / 文件不完整）
//   * 任何异常都不抛给 Dart（一律 `result.success(null)`），界面层回退占位图标。
//
// ## 已知限制（**诚实写在这里，别在报告里假装没有**）
//   1. 我们只把**文件头部**交给 retriever（≤ 6 MiB；文件本身 ≤ 6 MiB 时整份下）。
//      MP4 的 `moov` 若在**文件尾**（非 fast-start 的相机/录屏产物）时，头部片段
//      解析不出视频轨 ⇒ 本次抽帧失败（失败会被 Dart 侧记进负缓存，不会每次滚动
//      都重试）。带 **fast-start** 或 `moov` 在前的 mp4/mov 不受影响。
//   2. ★ 第 267 轮真机取证（Honor LGE-AN10 / Android 12）——**修正第 263 轮的
//      一条错误结论**：
//      * `/home/Video/60招基础街球S01E01.AVI`（191,779,926 B）失败的真正原因是
//        **本机平台的 `MediaExtractor` 根本没有 RIFF/AVI 解析器**，不是"没有
//        `idx1`"。`adb shell dumpsys media.extractor` 列出的 12 个 extractor 是
//        AAC/AMR/FFmpeg(ts,m2ts)/FLAC/MIDI/MP3/MP4/MP4-DTS/MPEG2-PS-TS/Matroska/
//        Ogg/WAV —— **没有任何 AVI/RIFF 项**；而该文件的**尾部确实有完整的
//        `idx1`**（offset 190,788,126，991,792 B = 61,987 条 × 16 B，
//        17,451 个 `00dc` + 44,536 个 `01wb`，与 `strh.dwLength` 逐一吻合）。
//        第 263 轮只读了最后 64 KiB、把 `idx1` **条目里的** 4 字节 chunk id
//        （`00dc`/`01wb`）当成了 movi 裸块 ⇒ 误判成"全文件没有 idx1"。
//      * 因此**再大的下载量也救不了 AVI**：容器层没有解析器，`setDataSource`
//        必然抛。**这是容器支持问题，不是接线/索引问题**。
//      * 视频编码本身**是**支持的：ffmpeg/ffprobe 实测该文件为
//        `FMP4`（MPEG-4 Part 2 / DivX-XviD 家族）320×240@15fps + mp3 44.1 kHz
//        立体声，19:23；本机有 `c2.android.mpeg4.decoder` / `OMX.google.mpeg4.decoder`
//        （`video/mp4v-es`）⇒ 「系统不支持这个编码」这句话对 **AVI 容器** 不成立，
//        报告与界面都不许这么写。
//      * ★★ **第 269 轮：缺的那层我们补上了** —— 平台没有的是**容器解析器**，不是解码器。
//        既然 `stage=open` 的根因是容器，那就**自己写 RIFF/AVI 走查**
//        （新文件 `AviFirstFrame.kt`），把裸 MPEG-4 ES 喂给平台 `MediaCodec`。
//        本文件里的接线：`stage=open` **且** 头字节嗅探出 `riff/avi` ⇒ 走
//        [aviFallback]；其它容器一律保持原行为。**AVI 路径是 fallback**，
//        MP4/MKV 等平台能开的文件一行都不进，快路径零影响（见 [AVI_CONTAINER]）。
//        新增 stage（`AviFirstFrame` 打印，tag 同为 `VideoFrameBridge`）：
//        `avi-parse` / `avi-keyframe` / `avi-codec` / `avi-decode` / `avi-ok`。
//   3. 真机取证（第 263 轮）：Photos 时间轴那条 `SVID_20250606_193253_1.mp4`
//      （1,876,693 B，H.264+AAC 1280×720，`moov` 在文件尾）**抽帧成功**，
//      产出 320×180 JPEG（磁盘缓存 + 像素都取到了）⇒ "抽不出来"是**逐文件**
//      的事实，不是"功能没做"。
//
// ## 第 267 轮新增：`extractFrameEx`（**失败也要说清是哪一段**）
// `extractFrame` 的契约（失败回 null）保持不变（Dart 侧 `core/media` 依赖它）。
// 新增的 `extractFrameEx` 在**失败时也回 Map**，带：
//   * `stage`        `ok` | `open` | `frame` | `encode` | `unexpected`
//   * `container`    仅按**文件头字节**嗅探：`riff/avi` | `riff` | `iso-bmff` |
//                    `ebml` | `asf` | `ogg` | `flv` | `mpeg-ts` | `mpeg-ps` | `unknown`
//   * `videoFourcc`  AVI 时从 `strf.biCompression` 读（如 `FMP4`/`XVID`/`MJPG`），
//                    读不到回落到 `strh.fccHandler`；其它容器留空
//   * `errorClass`/`error`/`hasVideo`/`w`/`h`  失败现场
// 这样 Dart 侧不必"猜"平台结论：容器是什么、卡在哪一段，都由这里给出。
//
// ## 第 296 轮新增：`extractFrameEx` 的**可选 URL 模式**
// 入参多两个（都可选）：`url` String、`headers` Map<String,String>。
//   * `url` 为空 ⇒ 老路径（本地文件），**键名与语义与第 269 轮逐字一致**；
//   * `url` 非空 ⇒ 经 `LocalRangeProxy`（同包）起本机回环代理，
//     `MediaMetadataRetriever` 的数据源换成 `http://127.0.0.1:<port>/v/<token>`
//     （真 NAS 支持 Range ⇒ 平台能拿到**整份文件**，不再是 6 MiB 头部）。
//     结束时 `unroute` 撤销路由。
//   * ★ **黑场引导场修复**：URL 模式下拿到帧先算平均亮度，`luma < 12` 时按
//     `0ms → 时长×10% → 时长×25% → 时长×50%` 重试，取第一个 luma ≥ 12 的帧；
//     全是黑的回最后一帧。
//   * 回包新增：`via`（`file` | `url-proxy`；AVI fallback 仍是 `avi-fallback`）、
//     `triedAtMs`（List<Int>）、`luma`（Int）、`durationMs`（Int，能拿到才给）。
//   * `probeContainer` / 自研 AVI fallback 只认本地文件 ⇒ URL 模式**跳过**。
// ## 第 42 轮新增：`extractFramePlayer`（media3 离屏渲染取帧）
// 平台 `MediaMetadataRetriever` 对部分码流（AVI 容器、某些 MKV/大 mp4）只回黑帧
// 或开不了容器，而**同一批文件用 App 的 media3 播放器能播**。所以新增这条：
//   * 入参：`url`(String, 必填)、`headers`(Map<String,String>?)、`atMs`(默认 0)、
//     `maxWidth`(默认 320)、`skipBlack`(Boolean, 默认 true)；
//   * 数据源**同一个** `LocalRangeProxy`(`http://127.0.0.1:<port>/v/<token>`)，
//     媒体栈只连明文回环 ⇒ **完全不碰 TLS**；
//   * offscreen `ExoPlayer` + `SurfaceTexture(0)`/`Surface`，监听
//     `Player.Listener.onRenderedFirstFrame()`（超时 9s ⇒ `stage=player-timeout`），
//     用 `PixelCopy` 读像素（API 24+）；读不回来 ⇒ `stage=player-readback`
//     （**绝不用黑图冒充成功**）；
//   * 黑场（luma < 12）按 `0ms → 时长×10% → 25% → 50%` 重试，取第一个亮的；
//   * 回包在既有键之外多：`via="player"`、`triedAtMs`、`luma`、`durationMs`；
//   * `finally` 里 release player/surface/surfaceTexture + `LocalRangeProxy.unroute`；
//   * `attach(engine, context)` 多一个 Context（`ExoPlayer.Builder` 需要）。
// 真机实测（Honor LGE-AN10 / Android 12，`/home/Video` 四文件）：AVI 由黑图变真帧
// （luma 1 → 103）、4.4 GB MKV 由黑变真（luma 0 → 59）。自研 AVI 解码器对黑帧
// 改为如实失败 ⇒ 文件模式回 `stage=avi-decode` + `error=all-black-frame:luma=1`。
package com.openviewai.synhub

import android.content.Context
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.PixelCopy
import android.view.Surface
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

object VideoFrameBridge {
    const val CHANNEL = "synhub/video_frame"

    /** logcat tag：`adb logcat -s VideoFrameBridge` 就能看到每一步的失败阶段。 */
    private const val TAG = "VideoFrameBridge"

    /** 默认取第一帧 */
    private const val DEFAULT_AT_MS = 0L

    /** 默认目标宽度（列表/网格缩略图足够，别把整帧位图塞进 Dart 堆） */
    private const val DEFAULT_MAX_WIDTH = 320

    /** JPEG 质量：85 是缩略图常用档，肉眼无损但体积只有 PNG 的零头 */
    private const val JPEG_QUALITY = 85

    /** 失败分层（`extractFrameEx` 回包里的 `stage`；与 Dart 侧逐字对应）。 */
    private const val STAGE_OK = "ok"
    private const val STAGE_OPEN = "open"
    private const val STAGE_FRAME = "frame"
    private const val STAGE_ENCODE = "encode"
    private const val STAGE_UNEXPECTED = "unexpected"

    // ★ 第 296 轮：`extractFrameEx` 回包新增的字段与阈值。

    /** `via` = 这一帧走的是哪条数据源：本地文件 / 本机 Range 代理。 */
    private const val VIA_FILE = "file"
    private const val VIA_URL = "url-proxy"

    /** 自研 AVI 路径的 `via`（**第 269 轮既有值，Dart 侧 `viaAviFallback` 依赖它**）。 */
    private const val VIA_AVI = "avi-fallback"

    // ★ 第 42 轮：`extractFramePlayer`（media3 离屏渲染）的 `via` 与新增 stage。
    //
    // 为什么加这条：平台 `MediaMetadataRetriever` 对部分码流（AVI 容器 / 某些 MKV、
    // 大 mp4）只回黑帧或开不了容器，而**同一批文件用 App 的 media3 播放器能播**。
    // 所以改用离屏 `ExoPlayer` 渲染 + `PixelCopy` 读回来拿真帧。

    /** `via` = media3 离屏播放器。 */
    private const val VIA_PLAYER = "player"

    /** 等 `onRenderedFirstFrame` 超时（单次 9 s，够慢盘起播；超时如实回这个 stage）。 */
    private const val STAGE_PLAYER_TIMEOUT = "player-timeout"

    /** 帧渲染出来了，但像素读不回来（PixelCopy 不可用/失败）——**绝不用黑图冒充成功**。 */
    private const val STAGE_PLAYER_READBACK = "player-readback"

    /** 播放器自身报错（容器/解码/网络）；附 `errorClass`/`error`。 */
    private const val STAGE_PLAYER_ERROR = "player-error"

    /** 单次等第一帧的上限（毫秒）。 */
    private const val PLAYER_FRAME_TIMEOUT_MS = 9000L

    /** 单次 `PixelCopy` 读回的上限（毫秒）。 */
    private const val PLAYER_READBACK_TIMEOUT_MS = 5000L

    /** 读不到视频尺寸时的读回位图兜底尺寸（16:9，只为 luma/缩略图）。 */
    private const val DEFAULT_PLAYER_WIDTH = 640
    private const val DEFAULT_PLAYER_HEIGHT = 360

    /** 读回位图的长边上限（防超大视频一次分配过多内存）。 */
    private const val MAX_PLAYER_FRAME_DIM = 2048

    /** 黑场判定阈值：平均亮度 < 12 视为黑色引导场，按时间递增重试。 */
    private const val LUMA_MIN = 12

    /** 算平均亮度前先缩到这么宽再逐像素（32px 足够，别在大图上循环）。 */
    private const val LUMA_SAMPLE_WIDTH = 32

    /** 容器嗅探只读文件头这么多字节（1 MiB 足够覆盖 hdrl + 前几个 movi 块）。 */
    private const val PROBE_BYTES = 1 shl 20

    /**
     * ★ 第 269 轮：**自研 AVI fallback 的唯一容器闸门**。
     *
     * 只有平台 `setDataSource` 抛了、**且**头字节嗅探出 `riff/avi` 时才走
     * [AviFirstFrame]（自写 RIFF 走查 + 平台 `MediaCodec`）。
     * MP4/MKV/… 平台能开的文件**一行都不会进**那条路 ⇒ 快路径零影响。
     * （Dart 侧 `aviFallbackApplies(container)` 是这个规则的离线镜像与单测钉子。）
     */
    private const val AVI_CONTAINER = "riff/avi"

    /** RIFF 块遍历的防死循环上限（脏 size 会造出死循环，必须封顶）。 */
    private const val AVI_MAX_CHUNKS = 4096

    /**
     * 抽帧是 CPU + IO 重活（解容器、解一帧、缩放、编码），
     * **绝不能**在平台主线程做 —— 单线程串行（Dart 侧已有 2 并发上限，
     * 这里再串行一道，避免多条 MediaMetadataRetriever 同时抢解码器）。
     */
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "video-frame-extract").apply { isDaemon = true }
    }

    /** ★ 第 42 轮：`ExoPlayer.Builder` 需要应用 Context；`attach` 时注入。 */
    @Volatile
    private var appContext: Context? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    fun attach(engine: FlutterEngine, context: Context) {
        appContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 本机一定能做（MediaMetadataRetriever 是框架自带）；
                    // 保留这个方法是为了 Dart 侧能"先问再做"，将来若有例外在这里收口。
                    "isSupported" -> result.success(true)

                    "extractFrame" -> {
                        val path = call.argument<String>("path")
                        val atMs = call.argument<Number>("atMs")?.toLong() ?: DEFAULT_AT_MS
                        val maxWidth = call.argument<Number>("maxWidth")?.toInt()
                            ?: DEFAULT_MAX_WIDTH
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "path 不能为空", null)
                            return@setMethodCallHandler
                        }
                        val src = File(path)
                        if (!src.isFile) {
                            result.error("no_source", "本地文件不存在", null)
                            return@setMethodCallHandler
                        }
                        executor.execute {
                            // 抽不出来 / 任何异常 → null（**不把 Kotlin 异常原文透给用户**）
                            //
                            // ★ 第 263 轮：**失败原因必须留在 logcat 里**。Dart 侧
                            // 只拿得到 null，分不清"容器解不了 / 没有视频轨 /
                            // 解码器不支持"——真机上这就是"只出一个图标、无从查起"
                            // 的根。`runCatching` 不再把异常丢掉。
                            val payload = runCatching {
                                extract(src, atMs, maxWidth.coerceAtLeast(1))
                            }.onFailure { e ->
                                Log.w(
                                    TAG,
                                    "stage=unexpected path=${src.name} " +
                                        "size=${src.length()} atMs=$atMs " +
                                        "err=${e.javaClass.simpleName}: ${e.message}",
                                )
                            }.getOrNull()
                            mainHandler.post { result.success(payload) }
                        }
                    }

                    // ★ 第 267 轮：**失败也回 Map**（带 `stage`/`container`/`videoFourcc`）。
                    // Dart 侧靠它把"容器打不开 / 没有视频轨 / 编码失败"翻译成人话，
                    // 不新增权限、不引入任何第三方库（纯 RIFF 头字节解析）。
                    "extractFrameEx" -> {
                        val urlArg = call.argument<String>("url")
                        val path = call.argument<String>("path")
                        val atMs = call.argument<Number>("atMs")?.toLong() ?: DEFAULT_AT_MS
                        val maxWidth = call.argument<Number>("maxWidth")?.toInt()
                            ?: DEFAULT_MAX_WIDTH
                        if (urlArg.isNullOrBlank()) {
                            // ---------- 老路径：本地文件（**键名与语义保持第 269 轮不变**）
                            if (path.isNullOrBlank()) {
                                result.error("bad_args", "path 不能为空", null)
                                return@setMethodCallHandler
                            }
                            val src = File(path)
                            if (!src.isFile) {
                                result.error("no_source", "本地文件不存在", null)
                                return@setMethodCallHandler
                            }
                            executor.execute {
                                // ★ **必须**兜住异常：否则 executor 线程抛出去，
                                // `result` 永远不会被回调 ⇒ Dart 侧 Future 永久挂起。
                                val payload = runCatching {
                                    extractDetailed(src, atMs, maxWidth.coerceAtLeast(1))
                                }.onFailure { e ->
                                    Log.w(
                                        TAG,
                                        "stage=unexpected path=${src.name} " +
                                            "size=${src.length()} atMs=$atMs " +
                                            "err=${e.javaClass.simpleName}: ${e.message}",
                                    )
                                }.getOrElse { unexpectedMap(it, VIA_FILE) }
                                mainHandler.post { result.success(payload) }
                            }
                        } else {
                            // ---------- ★ 第 296 轮新路径：URL 经本机 Range 代理
                            //
                            // 真 NAS 支持 Range ⇒ 平台 retriever 能拿到**整份文件**
                            // （不再是 6 MiB 头部），`moov` 在尾部的 mp4 / 4.4 GB 的
                            // MKV 因此可解析；黑场引导场由 [extractDetailedUrl] 重试修。
                            val targetUrl = urlArg
                            val headers = stringHeaders(call.argument<Map<*, *>>("headers"))
                            executor.execute {
                                var routedPath: String? = null
                                val payload = runCatching {
                                    val port = LocalRangeProxy.ensureStarted()
                                    routedPath = LocalRangeProxy.route(targetUrl, headers)
                                    val localUrl = "http://127.0.0.1:$port$routedPath"
                                    extractDetailedUrl(
                                        localUrl,
                                        atMs,
                                        maxWidth.coerceAtLeast(1),
                                    )
                                }.onFailure { e ->
                                    Log.w(
                                        TAG,
                                        "stage=unexpected via=url-proxy atMs=$atMs " +
                                            "err=${e.javaClass.simpleName}: ${e.message}",
                                    )
                                }.getOrElse { unexpectedMap(it, VIA_URL) }
                                // ★ 结束时**必须**撤销路由（否则 token + headers 泄漏）
                                routedPath?.let {
                                    runCatching { LocalRangeProxy.unroute(it) }
                                }
                                mainHandler.post { result.success(payload) }
                            }
                        }
                    }


                    // ★ 第 42 轮：**media3 离屏渲染取帧**（`extractFramePlayer`）。
                    //
                    // 数据源与 `extractFrameEx` 的 URL 模式**同一个** `LocalRangeProxy`
                    // （`http://127.0.0.1:<port>/v/<token>`）：媒体栈只连明文回环，
                    // **完全不需要碰 TLS**（媒体栈直连自签 NAS 会握手失败）。
                    //
                    // 实现：offscreen `ExoPlayer` + `SurfaceTexture(0)` 的 `Surface`，
                    // `Player.Listener.onRenderedFirstFrame()` 拿帧，`PixelCopy` 读像素；
                    // 黑场（luma < LUMA_MIN）按 `0 → 时长×10% → 25% → 50%` 重试。
                    // 线程：ExoPlayer 只能在有 Looper 的线程上访问，故每次调用起一条
                    // 临时 HandlerThread（跑完 quitSafely）；外层仍由串行 executor 保证
                    // **不并发抢解码器**。
                    "extractFramePlayer" -> {
                        val urlArg = call.argument<String>("url")
                        val headers = stringHeaders(call.argument<Map<*, *>>("headers"))
                        val atMs = call.argument<Number>("atMs")?.toLong() ?: DEFAULT_AT_MS
                        val maxWidth = call.argument<Number>("maxWidth")?.toInt()
                            ?: DEFAULT_MAX_WIDTH
                        val skipBlack = call.argument<Boolean>("skipBlack") ?: true
                        if (urlArg.isNullOrBlank()) {
                            result.error("bad_args", "url 不能为空", null)
                            return@setMethodCallHandler
                        }
                        val ctx = appContext
                        if (ctx == null) {
                            result.error("no_context", "应用 Context 未注入", null)
                            return@setMethodCallHandler
                        }
                        // ★ 临时探针日志（任务书明确允许）：拿到的 url 是不是 NAS 直链。
                        Log.i(
                            TAG,
                            "[framePlayer] stage=call atMs=$atMs maxWidth=$maxWidth " +
                                "skipBlack=$skipBlack headers=${headers.size} " +
                                "urlHost=${hostOfUrl(urlArg)}",
                        )
                        val targetUrl = urlArg
                        executor.execute {
                            var routedPath: String? = null
                            val payload = runCatching {
                                val port = LocalRangeProxy.ensureStarted()
                                routedPath = LocalRangeProxy.route(targetUrl, headers)
                                val localUrl = "http://127.0.0.1:$port$routedPath"
                                extractPlayerDetailed(
                                    ctx,
                                    localUrl,
                                    atMs,
                                    maxWidth.coerceAtLeast(1),
                                    skipBlack,
                                )
                            }.onFailure { e ->
                                Log.w(
                                    TAG,
                                    "[framePlayer] stage=unexpected " +
                                        "err=${e.javaClass.simpleName}: ${e.message}",
                                )
                            }.getOrElse { unexpectedMap(it, VIA_PLAYER) }
                            // ★ 结束时**必须**撤销路由（否则 token + headers 泄漏）
                            routedPath?.let {
                                runCatching { LocalRangeProxy.unroute(it) }
                            }
                            mainHandler.post { result.success(payload) }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 抽一帧 → 缩放 → **编成 JPEG** → 返回 Dart 能直接喂 `Image.memory` 的 Map。
     *
     * 返回 null = 这个本地片段给不出帧（**第 267 轮起改用 [extractDetailed] 实现**，
     * 老契约逐字不变：成功才有 Map、失败一律 null）。
     */
    private fun extract(src: File, atMs: Long, maxWidth: Int): HashMap<String, Any>? {
        val payload = extractDetailed(src, atMs, maxWidth)
        return if (payload["stage"] == STAGE_OK) payload else null
    }

    /**
     * 抽一帧 → 缩放 → **编成 JPEG**；**无论成败都返回一张 Map**（第 267 轮）。
     *
     * 分层与第 263 轮一致，**每一段失败都往 logcat 打一条 `stage=…`**
     * （tag `VideoFrameBridge`，release 也进 logcat）：
     *   * `stage=open`   —— `setDataSource` 抛了：**本机平台 `MediaExtractor`
     *                      认不出这个容器**（真机实测：RIFF/AVI 没有解析器）/
     *                      片段不完整（头部没有 `moov`）；
     *   * `stage=frame`  —— 容器开了但拿不到帧：没有视频轨 / 无关键帧 /
     *                      解码器不支持（连 `hasVideo`/宽高一起打出来，好分辨）；
     *   * `stage=encode` —— 帧有了但 JPEG 编码失败；
     *   * `stage=unexpected` —— 其它异常（`runCatching` 不再吞掉）。
     *
     * 返回的 Map **恒有** `stage`/`container`/`videoFourcc`；成功时另有
     * `bytes`/`encoding`/`mime`/`width`/`height`（自研 AVI 路径成功时多一个
     * `via=avi-fallback`），失败时另有 `errorClass`/`error`/`hasVideo`/`w`/`h`。
     *
     * ★ 第 269 轮新增的 AVI fallback 失败时 `stage` 会是
     * `avi-parse`/`avi-keyframe`/`avi-codec`/`avi-decode` 之一，`error` 是机器可读原因
     * （`fourcc-unsupported:<fourcc>` / `keyframe-outside-window:...` /
     * `decoder-unavailable:<mime>` / `eos-no-frame` …）；另有
     * `codecMime`/`aviMoviOffset`/`aviChunkOffset`/`aviChunkSize`/`aviEsFrames`/`aviEsBytes`
     * 等现场字段（Dart 侧读它们做日志与原因键，**不猜**）。
     */
    private fun extractDetailed(
        src: File,
        atMs: Long,
        maxWidth: Int,
    ): HashMap<String, Any> {
        val probe = probeContainer(src)
        // 先落一条**独立的** probe 行：第 263 轮那条 `stage=open …` 因此**逐字不变**，
        // 老的真机取证仍然可复现（只是前面多一行"这个文件是什么容器/什么编码"）。
        Log.i(
            TAG,
            "stage=probe path=${src.name} size=${src.length()} " +
                "container=${probe.container} videoFourcc=${probe.videoFourcc}",
        )
        val base = HashMap<String, Any>().apply {
            put("container", probe.container)
            put("videoFourcc", probe.videoFourcc)
            // 第 296 轮新增：本地文件路径的 `via`（AVI fallback 会在 aviFallback 里覆盖）
            put("via", VIA_FILE)
        }
        val retriever = MediaMetadataRetriever()
        try {
            try {
                retriever.setDataSource(src.absolutePath)
            } catch (e: Exception) {
                Log.w(
                    TAG,
                    "stage=open path=${src.name} size=${src.length()} " +
                        "err=${e.javaClass.simpleName}: ${e.message}",
                )
                // ★ 第 269 轮：平台认不出这个容器时，**只有 RIFF/AVI** 才走自研那条路
                // （自写容器解析 + 平台 MediaCodec）。其它容器保持第 261/267 轮行为。
                if (probe.container == AVI_CONTAINER) {
                    return aviFallback(src, maxWidth, base)
                }
                return base.apply {
                    put("stage", STAGE_OPEN)
                    put("errorClass", e.javaClass.simpleName)
                    put("error", e.message ?: "")
                }
            }
            val hasVideo = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO,
            )
            val rawW = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH,
            )
            val rawH = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT,
            )
            val frame = frameAt(retriever, atMs, maxWidth)
            if (frame == null) {
                Log.w(
                    TAG,
                    "stage=frame path=${src.name} atMs=$atMs " +
                        "hasVideo=$hasVideo w=$rawW h=$rawH",
                )
                return base.apply {
                    put("stage", STAGE_FRAME)
                    put("hasVideo", hasVideo ?: "")
                    put("w", rawW ?: "")
                    put("h", rawH ?: "")
                }
            }
            val encoded = encodeFrame(frame, maxWidth)
            if (encoded.frame == null) {
                val f = encoded.fail!!
                if (f.className != null) {
                    Log.w(
                        TAG,
                        "stage=encode path=${src.name} " +
                            "err=${f.className}: ${f.error}",
                    )
                    return base.apply {
                        put("stage", STAGE_ENCODE)
                        put("errorClass", f.className)
                        put("error", f.error)
                    }
                }
                Log.w(
                    TAG,
                    "stage=encode path=${src.name} ${f.error}",
                )
                return base.apply {
                    put("stage", STAGE_ENCODE)
                    put("error", f.error)
                }
            }
            return base.apply {
                put("stage", STAGE_OK)
                put("bytes", encoded.frame.bytes)
                put("encoding", "jpeg")
                put("mime", "image/jpeg")
                put("width", encoded.frame.width)
                put("height", encoded.frame.height)
            }
        } finally {
            runCatching { retriever.release() }
        }
    }

    // ------------------------------------------------------------ URL 模式（第 296 轮）
    //
    // 数据源 = [LocalRangeProxy] 给的 `http://127.0.0.1:<port>/v/<token>`：
    // 平台 retriever 的 Range 请求被原样转给真 NAS ⇒ 拿到的是**整份文件**，
    // 不再是 6 MiB 头部片段。`probeContainer` / 自研 AVI fallback 只认本地文件，
    // URL 模式下**跳过**（`container` 恒 unknown）。

    /**
     * URL 模式抽帧（**黑场引导场修复**是这一轮的核心）。
     *
     * 拿到帧后先算平均亮度：`luma < [LUMA_MIN]` 说明是视频开头的黑色引导场，
     * 按 `0ms → 时长×10% → 时长×25% → 时长×50%` 依次重试，取**第一个够亮**的帧；
     * 全是黑的就回最后一帧（缩略图宁可黑，也不要不出图）。
     *
     * 成功回包在既有键之外多：`via="url-proxy"`、`triedAtMs`（List<Int>，试过的时间点）、
     * `luma`（Int，最终帧平均亮度）、`durationMs`（Int，读得到才给）。
     */
    private fun extractDetailedUrl(
        localUrl: String,
        atMs: Long,
        maxWidth: Int,
    ): HashMap<String, Any> {
        val base = HashMap<String, Any>().apply {
            put("container", "unknown")
            put("videoFourcc", "")
            put("via", VIA_URL)
        }
        // 只打 atMs / maxWidth，**不打 localUrl**（token 虽是随机的，也没必要进日志）。
        Log.i(TAG, "stage=probe via=url-proxy atMs=$atMs maxWidth=$maxWidth")
        val retriever = MediaMetadataRetriever()
        try {
            try {
                retriever.setDataSource(localUrl)
            } catch (e: Exception) {
                Log.w(
                    TAG,
                    "stage=open via=url-proxy atMs=$atMs " +
                        "err=${e.javaClass.simpleName}: ${e.message}",
                )
                return base.apply {
                    put("stage", STAGE_OPEN)
                    put("errorClass", e.javaClass.simpleName)
                    put("error", e.message ?: "")
                }
            }
            val hasVideo = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO,
            )
            val rawW = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH,
            )
            val rawH = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT,
            )
            val durationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toIntOrNull()
            if (durationMs != null && durationMs > 0) base["durationMs"] = durationMs

            val tried = ArrayList<Int>()
            val (frame, luma) = firstBrightFrame(retriever, atMs, maxWidth, durationMs, tried)
            base["triedAtMs"] = tried
            base["luma"] = luma
            if (frame == null) {
                Log.w(
                    TAG,
                    "stage=frame via=url-proxy atMs=$atMs " +
                        "hasVideo=$hasVideo w=$rawW h=$rawH",
                )
                return base.apply {
                    put("stage", STAGE_FRAME)
                    put("hasVideo", hasVideo ?: "")
                    put("w", rawW ?: "")
                    put("h", rawH ?: "")
                }
            }
            val encoded = encodeFrame(frame, maxWidth)
            frame.recycle()
            if (encoded.frame == null) {
                val f = encoded.fail!!
                Log.w(
                    TAG,
                    "stage=encode via=url-proxy err=${f.className}: ${f.error}",
                )
                return base.apply {
                    put("stage", STAGE_ENCODE)
                    if (f.className != null) put("errorClass", f.className)
                    put("error", f.error)
                }
            }
            return base.apply {
                put("stage", STAGE_OK)
                put("bytes", encoded.frame.bytes)
                put("encoding", "jpeg")
                put("mime", "image/jpeg")
                put("width", encoded.frame.width)
                put("height", encoded.frame.height)
            }
        } finally {
            runCatching { retriever.release() }
        }
    }

    /**
     * 取第一个"够亮"的帧：先试 [atMs]，若 `luma < [LUMA_MIN]` 再按
     * `0ms → 时长×10% → 时长×25% → 时长×50%` 重试（跳过与 [atMs] 重复的点）。
     *
     * 全部试完都不亮 → 返回**最后一帧**（`luma` 即它的亮度）。
     * [tried] 里按顺序记下每个真正取过帧的时间点（毫秒）。
     *
     * ★ 复用同一个 retriever（`setDataSource` 很贵），不重复建连。
     */
    private fun firstBrightFrame(
        retriever: MediaMetadataRetriever,
        atMs: Long,
        maxWidth: Int,
        durationMs: Int?,
        tried: MutableList<Int>,
    ): Pair<Bitmap?, Int> {
        var best: Bitmap? = null
        var bestLuma = 0

        val first = frameAt(retriever, atMs, maxWidth)
        if (first != null) {
            tried.add(atMs.toInt())
            best = first
            bestLuma = averageLuma(first)
            Log.i(TAG, "stage=luma via=url-proxy atMs=$atMs luma=$bestLuma")
        }
        if (best != null && bestLuma >= LUMA_MIN) return best to bestLuma

        val retries = ArrayList<Long>()
        retries.add(0L)
        if (durationMs != null && durationMs > 0) {
            val d = durationMs.toLong()
            retries.add(d * 10 / 100)
            retries.add(d * 25 / 100)
            retries.add(d * 50 / 100)
        }
        for (t in retries) {
            if (best != null && bestLuma >= LUMA_MIN) break
            if (t == atMs) continue // 首个时间点已经试过
            val f = frameAt(retriever, t, maxWidth) ?: continue
            tried.add(t.toInt())
            val l = averageLuma(f)
            Log.i(TAG, "stage=luma via=url-proxy atMs=$t luma=$l")
            if (best != null && best !== f) best.recycle()
            best = f
            bestLuma = l
        }
        return best to bestLuma
    }

    /**
     * 一帧的平均亮度（0..255，标准 luma 权重 `0.299R + 0.587G + 0.114B`）。
     *
     * **先缩到 ≤ [LUMA_SAMPLE_WIDTH] 宽再逐像素**（32px 样本足够判黑场，
     * 别在 320px 甚至整帧上循环）；读像素失败回 0（当作黑，触发重试，**不抛**）。
     */
    internal fun averageLuma(bitmap: Bitmap): Int {
        return try {
            if (bitmap.width <= 0 || bitmap.height <= 0) return 0
            val w = minOf(bitmap.width, LUMA_SAMPLE_WIDTH)
            val h = (bitmap.height.toLong() * w / bitmap.width).toInt().coerceAtLeast(1)
            val small = if (w >= bitmap.width) bitmap else Bitmap.createScaledBitmap(bitmap, w, h, true)
            val sw = small.width
            val sh = small.height
            val pixels = IntArray(sw * sh)
            small.getPixels(pixels, 0, sw, 0, 0, sw, sh)
            if (small !== bitmap) small.recycle()
            if (pixels.isEmpty()) {
                0
            } else {
                var sum = 0L
                for (p in pixels) {
                    val r = (p shr 16) and 0xFF
                    val g = (p shr 8) and 0xFF
                    val b = p and 0xFF
                    sum += (r * 299 + g * 587 + b * 114) / 1000
                }
                (sum / pixels.size).toInt()
            }
        } catch (e: Exception) {
            Log.w(TAG, "stage=luma err=${e.javaClass.simpleName}: ${e.message}")
            0
        }
    }

    /**
     * `headers` 入参只收 String→String（Flutter Map 解出的值类型可能更宽，
     * 宽的那部分直接丢弃，不让它把整次抽帧带崩）。
     */
    private fun stringHeaders(raw: Map<*, *>?): Map<String, String> {
        if (raw.isNullOrEmpty()) return emptyMap()
        val out = HashMap<String, String>(raw.size)
        raw.forEach { (k, v) ->
            if (k is String && v is String && k.isNotBlank()) out[k] = v
        }
        return out
    }

    /** 兜底回包（未被分段捕获的异常）：恒有 `stage`/`container`/`videoFourcc`/`via`。 */
    private fun unexpectedMap(e: Throwable, via: String): HashMap<String, Any> =
        HashMap<String, Any>().apply {
            put("stage", STAGE_UNEXPECTED)
            put("container", "unknown")
            put("videoFourcc", "")
            put("via", via)
            put("errorClass", e.javaClass.simpleName)
            put("error", e.message ?: "")
        }

    // ------------------------------------------------------------ media3 离屏取帧（第 42 轮）
    //
    // 数据源同 `extractFrameEx`：`LocalRangeProxy` 的
    // `http://127.0.0.1:<port>/v/<token>` ⇒ 媒体栈只连明文回环，**不需要碰 TLS**
    // （真正带 TLS 的那一跳由 LocalRangeProxy 的 HttpsURLConnection 走，继承
    // `MediaPlayerBridge.setTlsPolicy` 的放宽政策）。
    //
    // 渲染：offscreen `ExoPlayer` + `SurfaceTexture(0)` 的 `Surface`，监听
    // `Player.Listener.onRenderedFirstFrame()`；拿到帧后按 `skipBlack` 重试
    // （`0 → 时长×10% → 25% → 50%`），取第一个 luma ≥ [LUMA_MIN] 的帧。
    //
    // 读回像素：优先 `PixelCopy.request(Surface, Bitmap, …)`（API 24+）；
    // 读不回来**如实**回 `stage=player-readback` —— **绝不用黑图冒充成功**。
    //
    // 线程：ExoPlayer 只能在**有 Looper** 的线程上创建/访问，所以每次调用起一条
    // 临时 `HandlerThread`（跑完 `quitSafely`）；外层仍由**串行 executor** 保证
    // 不会并发抢解码器。所有资源在 `finally` 里 `release()`。

    /** 只取主机名进日志（**不打完整 URL**：里面带 `_sid` 查询串）。 */
    private fun hostOfUrl(url: String): String = runCatching {
        java.net.URL(url).host ?: ""
    }.getOrDefault("")

    /**
     * media3 离屏抽帧（**黑场引导场重试**与 `extractDetailedUrl` 同口径）。
     *
     * 成功回包：既有键之外多 `via="player"`、`triedAtMs`、`luma`、`durationMs`。
     * 失败如实分层：`player-timeout` / `player-readback` / `player-error` / `encode`。
     */
    private fun extractPlayerDetailed(
        context: Context,
        localUrl: String,
        atMs: Long,
        maxWidth: Int,
        skipBlack: Boolean,
    ): HashMap<String, Any> {
        val base = HashMap<String, Any>().apply {
            put("container", "unknown")
            put("videoFourcc", "")
            put("via", VIA_PLAYER)
        }
        // 只打 atMs / maxWidth，**不打 localUrl**（token 虽随机，也没必要进日志）。
        Log.i(
            TAG,
            "[framePlayer] stage=probe atMs=$atMs maxWidth=$maxWidth skipBlack=$skipBlack",
        )

        val surfaceTexture = SurfaceTexture(0)
        val surface = Surface(surfaceTexture)
        val thread = HandlerThread("video-frame-player")
        thread.start()
        val handler = Handler(thread.looper)
        val playerRef = AtomicReference<ExoPlayer?>(null)
        val renderLatch = AtomicReference(CountDownLatch(1))
        val errorRef = AtomicReference<PlaybackException?>(null)
        val createErrorRef = AtomicReference<Throwable?>(null)
        val videoSizeRef = AtomicReference<VideoSize?>(null)
        val tried = ArrayList<Int>()
        var lastLuma = 0
        var durationMs: Int? = null

        try {
            val started = CountDownLatch(1)
            handler.post {
                try {
                    val player = ExoPlayer.Builder(context)
                        .setLooper(thread.looper)
                        .build()
                    playerRef.set(player)
                    player.addListener(
                        object : Player.Listener {
                            override fun onRenderedFirstFrame() {
                                renderLatch.get().countDown()
                            }

                            override fun onPlayerError(error: PlaybackException) {
                                errorRef.set(error)
                                renderLatch.get().countDown()
                            }

                            override fun onVideoSizeChanged(videoSize: VideoSize) {
                                if (videoSize.width > 0 && videoSize.height > 0) {
                                    videoSizeRef.set(videoSize)
                                }
                            }
                        },
                    )
                    player.setVideoSurface(surface)
                    // `setMediaItem(item, startPositionMs)`：prepare 后直接停在 atMs，
                    // 避免"先渲染 0ms 再 seek"多解一帧。
                    player.setMediaItem(MediaItem.fromUri(localUrl), atMs)
                    player.prepare()
                    player.playWhenReady = true
                } catch (e: Exception) {
                    createErrorRef.set(e)
                    Log.w(
                        TAG,
                        "[framePlayer] stage=create err=${e.javaClass.simpleName}: ${e.message}",
                    )
                    renderLatch.get().countDown()
                } finally {
                    started.countDown()
                }
            }
            started.await(3, TimeUnit.SECONDS)

            createErrorRef.get()?.let { e ->
                return base.apply {
                    put("stage", STAGE_PLAYER_ERROR)
                    put("errorClass", e.javaClass.simpleName)
                    put("error", e.message ?: "player-create-failed")
                }
            }

            // ① 第一帧（起始位置 = atMs）
            if (!renderLatch.get().await(PLAYER_FRAME_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                Log.w(TAG, "[framePlayer] stage=player-timeout atMs=$atMs")
                return base.apply {
                    put("stage", STAGE_PLAYER_TIMEOUT)
                    put("triedAtMs", tried)
                    put("error", "rendered-first-frame-timeout")
                }
            }
            errorRef.get()?.let { e ->
                Log.w(TAG, "[framePlayer] stage=player-error code=${e.errorCodeName}")
                return base.apply {
                    put("stage", STAGE_PLAYER_ERROR)
                    put("errorClass", e.javaClass.simpleName)
                    put("error", e.errorCodeName)
                }
            }

            durationMs = readPlayerDuration(playerRef, handler)
            if (durationMs != null) base["durationMs"] = durationMs

            var bitmap = readPlayerFrame(surface, videoSizeRef, handler)
            if (bitmap != null) {
                tried.add(atMs.toInt())
                lastLuma = averageLuma(bitmap)
                Log.i(TAG, "[framePlayer] stage=luma atMs=$atMs luma=$lastLuma")
            }

            // ② 黑场重试（只对黑帧做，且 skipBlack 打开时）
            if (bitmap != null && skipBlack && lastLuma < LUMA_MIN) {
                val retries = ArrayList<Long>()
                retries.add(0L)
                val d = durationMs
                if (d != null && d > 0) {
                    val dl = d.toLong()
                    retries.add(dl * 10 / 100)
                    retries.add(dl * 25 / 100)
                    retries.add(dl * 50 / 100)
                }
                for (t in retries) {
                    if (lastLuma >= LUMA_MIN) break
                    if (t == atMs) continue
                    renderLatch.set(CountDownLatch(1))
                    handler.post { playerRef.get()?.seekTo(t) }
                    if (!renderLatch.get().await(PLAYER_FRAME_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                        Log.w(TAG, "[framePlayer] stage=player-timeout seek=$t")
                        break
                    }
                    if (errorRef.get() != null) break
                    val f = readPlayerFrame(surface, videoSizeRef, handler) ?: continue
                    tried.add(t.toInt())
                    val l = averageLuma(f)
                    Log.i(TAG, "[framePlayer] stage=luma atMs=$t luma=$l")
                    if (bitmap !== f) bitmap?.recycle()
                    bitmap = f
                    lastLuma = l
                }
            }

            base["triedAtMs"] = tried
            base["luma"] = lastLuma
            if (bitmap == null) {
                Log.w(TAG, "[framePlayer] stage=player-readback atMs=$atMs")
                return base.apply {
                    put("stage", STAGE_PLAYER_READBACK)
                    put("error", "pixelcopy-unavailable")
                }
            }
            val encoded = encodeFrame(bitmap, maxWidth)
            if (encoded.frame == null) {
                val f = encoded.fail!!
                Log.w(TAG, "[framePlayer] stage=encode err=${f.className}: ${f.error}")
                return base.apply {
                    put("stage", STAGE_ENCODE)
                    if (f.className != null) put("errorClass", f.className)
                    put("error", f.error)
                }
            }
            Log.i(
                TAG,
                "[framePlayer] stage=ok luma=$lastLuma tried=$tried " +
                    "bytes=${encoded.frame.bytes.size} " +
                    "${encoded.frame.width}x${encoded.frame.height}",
            )
            return base.apply {
                put("stage", STAGE_OK)
                put("bytes", encoded.frame.bytes)
                put("encoding", "jpeg")
                put("mime", "image/jpeg")
                put("width", encoded.frame.width)
                put("height", encoded.frame.height)
            }
        } finally {
            // ★ 所有资源都在这条 HandlerThread 上释放（player → surface → texture），
            // 释放完再 quitSafely；外层再兜一次，保证**不泄漏线程/播放器**。
            val done = CountDownLatch(1)
            handler.post {
                runCatching { playerRef.get()?.release() }
                runCatching { surface.release() }
                runCatching { surfaceTexture.release() }
                done.countDown()
            }
            done.await(3, TimeUnit.SECONDS)
            runCatching { surface.release() }
            runCatching { surfaceTexture.release() }
            thread.quitSafely()
        }
    }

    /** 读播放器时长（`C.TIME_UNSET` = 还不知道 ⇒ null）；在播放器线程上读。 */
    private fun readPlayerDuration(
        playerRef: AtomicReference<ExoPlayer?>,
        handler: Handler,
    ): Int? {
        val latch = CountDownLatch(1)
        val out = AtomicReference(C.TIME_UNSET)
        handler.post {
            out.set(playerRef.get()?.duration ?: C.TIME_UNSET)
            latch.countDown()
        }
        latch.await(1, TimeUnit.SECONDS)
        val d = out.get()
        return if (d > 0 && d != C.TIME_UNSET) d.toInt() else null
    }

    /**
     * 从渲染目标 [surface] 读回一帧 Bitmap（`PixelCopy`，API 24+）。
     *
     * 位图尺寸取视频尺寸（读不到用 [DEFAULT_PLAYER_WIDTH]×[DEFAULT_PLAYER_HEIGHT]），
     * 长边封顶 [MAX_PLAYER_FRAME_DIM]。**读不回来就回 null**（调用方给
     * `stage=player-readback`）——这里的 null 永远不会被当成黑图。
     */
    private fun readPlayerFrame(
        surface: Surface,
        videoSizeRef: AtomicReference<VideoSize?>,
        handler: Handler,
    ): Bitmap? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return null
        val vs = videoSizeRef.get()
        val rawW = if (vs != null && vs.width > 0) vs.width else DEFAULT_PLAYER_WIDTH
        val rawH = if (vs != null && vs.height > 0) vs.height else DEFAULT_PLAYER_HEIGHT
        val w = rawW.coerceAtMost(MAX_PLAYER_FRAME_DIM)
        val h = (rawH.toLong() * w / rawW).toInt().coerceAtLeast(1)
        val bmp = try {
            Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        } catch (e: Exception) {
            Log.w(TAG, "[framePlayer] bitmap alloc failed: ${e.javaClass.simpleName}")
            return null
        }
        val latch = CountDownLatch(1)
        val code = AtomicInteger(PixelCopy.ERROR_UNKNOWN)
        try {
            PixelCopy.request(
                surface,
                bmp,
                { result ->
                    code.set(result)
                    latch.countDown()
                },
                handler,
            )
        } catch (e: Exception) {
            Log.w(
                TAG,
                "[framePlayer] pixelcopy threw ${e.javaClass.simpleName}: ${e.message}",
            )
            bmp.recycle()
            return null
        }
        if (!latch.await(PLAYER_READBACK_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            Log.w(TAG, "[framePlayer] pixelcopy timeout")
            bmp.recycle()
            return null
        }
        if (code.get() != PixelCopy.SUCCESS) {
            Log.w(TAG, "[framePlayer] pixelcopy fail code=${code.get()}")
            bmp.recycle()
            return null
        }
        return bmp
    }

    // ------------------------------------------------------------ 编码（两路共用）

    /** 编好的 JPEG + 实际像素尺寸（平台路径与自研 AVI 路径共用的产出）。 */
    private class EncodedFrame(val bytes: ByteArray, val width: Int, val height: Int)

    /**
     * 编码失败的两种形状 —— 分开是为了让 logcat 里那两条 `stage=encode` 与第 261 轮
     * **逐字一致**（`err=<类名>: <消息>` 与 `ok=.. bytes=..` 是两种不同的行）。
     */
    private class EncodeFailure(val className: String?, val error: String)

    private class EncodeOutcome(val frame: EncodedFrame?, val fail: EncodeFailure?)

    /**
     * 帧 → 等比缩 → **JPEG**（`Bitmap.compress(JPEG, [JPEG_QUALITY])`）。
     *
     * ★ 第 269 轮把第 261 轮的这段抽成共用函数：平台路径与自研 AVI 路径**走同一条**，
     * 所以 Dart 侧拿到的恒是 `image/jpeg`（`mime`/`encoding` 也逐字不变）。
     */
    private fun encodeFrame(frame: Bitmap, maxWidth: Int): EncodeOutcome {
        val scaled = scaleToWidth(frame, maxWidth)
        val out = ByteArrayOutputStream()
        val ok = try {
            scaled.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
        } catch (e: Exception) {
            return EncodeOutcome(
                null,
                EncodeFailure(e.javaClass.simpleName, e.message ?: ""),
            )
        }
        val bytes = out.toByteArray()
        if (!ok || bytes.isEmpty()) {
            return EncodeOutcome(
                null,
                EncodeFailure(null, "ok=$ok bytes=${bytes.size}"),
            )
        }
        return EncodeOutcome(EncodedFrame(bytes, scaled.width, scaled.height), null)
    }

    // ------------------------------------------------------------ 自研 AVI fallback（第 269 轮）

    /**
     * 平台开不了 AVI 时的**自研兜底**：`AviFirstFrame`（自写 RIFF 走查 + 平台 `MediaCodec`）
     * 解出第一帧 Bitmap，再走上面**同一条** JPEG 编码路径。
     *
     * 失败**不抛**，回一张带**新 stage**（`avi-parse`/`avi-keyframe`/`avi-codec`/`avi-decode`）
     * 与机器可读 `error` 的 Map —— 日志侧 `AviFirstFrame` 已经逐段打过 `stage=`，
     * 这里只负责把它翻成 Dart 契约里那几张字段。
     */
    private fun aviFallback(
        src: File,
        maxWidth: Int,
        base: HashMap<String, Any>,
    ): HashMap<String, Any> {
        // 第 296 轮：这条路的 `via` 恒为 avi-fallback（成功/失败都一样，
        // Dart 侧 `viaAviFallback` 与 `failure.aviFallbackUsed` 都靠它分辨"哪条路报的"）。
        base["via"] = VIA_AVI
        val avi = runCatching {
            AviFirstFrame.extractFrame(src, maxWidth)
        }.onFailure { e ->
            // 兜底里再出异常也不许把 executor 线程抛穿（否则 Dart 侧 Future 永久挂起）
            Log.w(
                TAG,
                "stage=avi-decode path=${src.name} " +
                    "err=${e.javaClass.simpleName}: ${e.message}",
            )
        }.getOrNull() ?: return base.apply {
            put("stage", STAGE_OPEN)
            put("errorClass", "AviFallbackThrew")
            put("error", "avi-fallback-unexpected")
        }

        // fourcc 以自研走查为准（同一份字节、比 1 MiB 嗅探走得更全）；读不到才保留嗅探值。
        if (avi.fourcc.isNotEmpty()) base["videoFourcc"] = avi.fourcc
        base["codecMime"] = avi.mime
        base["aviMoviOffset"] = avi.moviOffset
        base["aviChunkOffset"] = avi.chunkOffset
        base["aviChunkSize"] = avi.chunkSize
        base["aviScannedChunks"] = avi.scannedChunks
        base["aviVideoChunks"] = avi.videoChunks
        base["aviEsFrames"] = avi.esFrames
        base["aviEsBytes"] = avi.esBytes
        base["aviW"] = avi.width
        base["aviH"] = avi.height
        if (avi.fps > 0) base["aviFps"] = avi.fps
        if (avi.frameCount > 0) base["aviFrames"] = avi.frameCount

        val bitmap = avi.bitmap
        if (bitmap == null) {
            return base.apply {
                put("stage", avi.stage)
                // `error` 沿用第 267 轮的失败契约；`aviReason` 是**机器可读**的
                // 自研路径原因（Dart 侧只读这一个进 `reason=/why=`，别把 open 的
                // 异常消息也当原因，那样日志会重复一遍）。
                put("aviReason", avi.reason)
                put("error", avi.reason)
            }
        }
        val encoded = encodeFrame(bitmap, maxWidth)
        if (encoded.frame == null) {
            val f = encoded.fail!!
            if (f.className != null) {
                Log.w(
                    TAG,
                    "stage=encode path=${src.name} " +
                        "err=${f.className}: ${f.error}",
                )
                return base.apply {
                    put("stage", STAGE_ENCODE)
                    put("errorClass", f.className)
                    put("error", f.error)
                }
            }
            Log.w(TAG, "stage=encode path=${src.name} ${f.error}")
            return base.apply {
                put("stage", STAGE_ENCODE)
                put("error", f.error)
            }
        }
        return base.apply {
            put("stage", STAGE_OK)
            put("via", VIA_AVI)
            put("bytes", encoded.frame.bytes)
            put("encoding", "jpeg")
            put("mime", "image/jpeg")
            put("width", encoded.frame.width)
            put("height", encoded.frame.height)
        }
    }

    // ------------------------------------------------------------ 容器嗅探
    //
    // **纯字节解析，零依赖**。只读文件**头部 ≤ [PROBE_BYTES]**，用来回答
    // "Dart 侧那个后缀（`.avi`）在这台机器上到底对应什么容器、什么视频编码"。
    // 不解析 movi/帧数据 —— 那是解码器的事，这里只给"是什么"。
    private data class ContainerProbe(val container: String, val videoFourcc: String)

    private fun probeContainer(src: File): ContainerProbe {
        // ⚠️ **不要用 `InputStream.readNBytes`**：它是 Java 9 API，Android 上
        // 直到 API 33 才有（本仓 minSdk 24）⇒ 手写有界读取。
        val b = runCatching {
            val buf = ByteArray(PROBE_BYTES)
            var n = 0
            src.inputStream().use { ins ->
                while (n < buf.size) {
                    val r = ins.read(buf, n, buf.size - n)
                    if (r <= 0) break
                    n += r
                }
            }
            if (n == buf.size) buf else buf.copyOf(n)
        }.getOrNull() ?: return ContainerProbe("unknown", "")
        if (b.size < 12) return ContainerProbe("unknown", "")
        // RIFF/AVI（`RIFF????AVI `）
        if (b.ascii(0) == "RIFF") {
            val form = b.ascii(8)
            return if (form == "AVI ") {
                ContainerProbe("riff/avi", aviVideoFourcc(b))
            } else {
                ContainerProbe("riff", "")
            }
        }
        // ISO-BMFF（`????ftyp`）
        if (b.ascii(4) == "ftyp") return ContainerProbe("iso-bmff", "")
        // Matroska/WebM（EBML）
        if (b[0] == 0x1A.toByte() && b[1] == 0x45.toByte() &&
            b[2] == 0xDF.toByte() && b[3] == 0xA3.toByte()
        ) {
            return ContainerProbe("ebml", "")
        }
        // ASF/WMV（GUID 30 26 B2 75 8E 66 CF 11）
        if (b[0] == 0x30.toByte() && b[1] == 0x26.toByte() &&
            b[2] == 0xB2.toByte() && b[3] == 0x75.toByte()
        ) {
            return ContainerProbe("asf", "")
        }
        if (b.ascii(0) == "OggS") return ContainerProbe("ogg", "")
        if (b.ascii(0) == "FLV\u0001") return ContainerProbe("flv", "")
        // MPEG-TS：188 字节一包，同步字节 0x47（查 5 个包）
        if (b.size > 188 * 4 && b[0] == 0x47.toByte() &&
            b[188] == 0x47.toByte() && b[376] == 0x47.toByte() &&
            b[564] == 0x47.toByte()
        ) {
            return ContainerProbe("mpeg-ts", "")
        }
        // MPEG-PS：pack start code 00 00 01 BA
        if (b.size > 4 && b[0] == 0.toByte() && b[1] == 0.toByte() &&
            b[2] == 1.toByte() && b[3] == 0xBA.toByte()
        ) {
            return ContainerProbe("mpeg-ps", "")
        }
        return ContainerProbe("unknown", "")
    }

    /**
     * 从 AVI 的 `hdrl` → `LIST strl` 里取**视频** track 的编码 fourcc。
     *
     * 优先 `strf.biCompression`（BITMAPINFOHEADER 偏移 +16），拿不到再回落
     * `strh.fccHandler`。真机实测 `60招基础街球S01E01.AVI` ⇒ **`FMP4`**
     * （`strh.fccType=vids`、`strh.fccHandler=FMP4`、`strf.biCompression=FMP4`）。
     */
    private fun aviVideoFourcc(b: ByteArray): String {
        var off = 12 // 跳过 `RIFF`(4) + size(4) + `AVI `(4)
        var guard = 0
        while (off + 8 <= b.size && guard++ < AVI_MAX_CHUNKS) {
            val id = b.ascii(off)
            val size = le32(b, off + 4)
            if (size < 0) return ""
            if (id == "LIST" && off + 12 <= b.size && b.ascii(off + 8) == "hdrl") {
                val end = minOf(off + 8 + size, b.size)
                val found = strlVideoFourcc(b, off + 12, end)
                if (found.isNotEmpty()) return found
            }
            val step = 8 + size + (size and 1)
            if (step <= 8) return "" // 防死循环（脏 size）
            off += step
        }
        return ""
    }

    /** 在 `hdrl` 体内逐个 `LIST strl` 找 `fccType == vids` 的 track。 */
    private fun strlVideoFourcc(b: ByteArray, from: Int, to: Int): String {
        var off = from
        var guard = 0
        while (off + 8 <= to && guard++ < AVI_MAX_CHUNKS) {
            val id = b.ascii(off)
            val size = le32(b, off + 4)
            if (size < 0) return ""
            if (id == "LIST" && off + 12 <= b.size && b.ascii(off + 8) == "strl") {
                val found = oneStrlVideoFourcc(b, off + 12, minOf(off + 8 + size, b.size))
                if (found.isNotEmpty()) return found
            }
            val step = 8 + size + (size and 1)
            if (step <= 8) return ""
            off += step
        }
        return ""
    }

    private fun oneStrlVideoFourcc(b: ByteArray, from: Int, to: Int): String {
        var off = from
        var type = ""
        var handler = ""
        var guard = 0
        while (off + 8 <= to && guard++ < AVI_MAX_CHUNKS) {
            val id = b.ascii(off)
            val size = le32(b, off + 4)
            if (size < 0) return ""
            if (id == "strh" && size >= 8 && off + 16 <= b.size) {
                type = b.ascii(off + 8)
                handler = fourccOrHex(b, off + 12)
            } else if (id == "strf" && size >= 20 && off + 8 + 20 <= b.size) {
                if (type == "vids") {
                    val comp = fourccOrHex(b, off + 8 + 16)
                    return if (comp.isNotEmpty() && !comp.startsWith("0x")) {
                        comp
                    } else {
                        handler
                    }
                }
            }
            val step = 8 + size + (size and 1)
            if (step <= 8) return ""
            off += step
        }
        return if (type == "vids") handler else ""
    }

    /** 4 字节 fourcc：全是可打印 ASCII 就当时串，否则给 `0x%08X`（如音频 `0x00000001`）。 */
    private fun fourccOrHex(b: ByteArray, off: Int): String {
        if (off + 4 > b.size) return ""
        var printable = true
        for (i in off until off + 4) {
            val c = b[i].toInt() and 0xFF
            if (c < 0x20 || c > 0x7E) printable = false
        }
        if (printable) return b.ascii(off)
        val v = le32(b, off)
        return String.format("0x%08X", v)
    }

    /** 小端 32 位（RIFF 全部是小端）。 */
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

    /** API 27+ 让系统按目标尺寸出帧；更低版本出整帧再由 [scaleToWidth] 缩。 */
    private fun frameAt(
        retriever: MediaMetadataRetriever,
        atMs: Long,
        maxWidth: Int,
    ): Bitmap? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            val size = scaledSize(retriever, maxWidth)
                ?: return retriever.getFrameAtTime(
                    atMs,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                )
            return retriever.getScaledFrameAtTime(
                atMs,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                size.first,
                size.second,
            )
        }
        // API 24..26：没有 getScaledFrameAtTime，走整帧 + 手工缩放
        return retriever.getFrameAtTime(atMs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
    }

    /**
     * 目标尺寸 = 原始宽高按 [maxWidth] 等比缩。
     *
     * 读不到宽高（`null`）时返回 null，调用方退回"整帧"路径。
     * 旋转 90/270 的视频宽高要**换过来**（否则缩放比例会算歪）。
     */
    private fun scaledSize(
        retriever: MediaMetadataRetriever,
        maxWidth: Int,
    ): Pair<Int, Int>? {
        val rawW = retriever
            .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
            ?.toIntOrNull()
            ?: return null
        val rawH = retriever
            .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
            ?.toIntOrNull()
            ?: return null
        if (rawW <= 0 || rawH <= 0) return null
        val rotation = retriever
            .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
            ?.toIntOrNull()
            ?: 0
        val swapped = rotation == 90 || rotation == 270
        val width = if (swapped) rawH else rawW
        val height = if (swapped) rawW else rawH
        if (width <= maxWidth) return width to height
        val scaledH = (height.toLong() * maxWidth / width).toInt().coerceAtLeast(1)
        return maxWidth to scaledH
    }

    /** 已经比目标小就别再缩放（避免无意义的位图拷贝）。 */
    private fun scaleToWidth(bitmap: Bitmap, maxWidth: Int): Bitmap {
        if (bitmap.width <= maxWidth) return bitmap
        val height = (bitmap.height.toLong() * maxWidth / bitmap.width)
            .toInt()
            .coerceAtLeast(1)
        val scaled = Bitmap.createScaledBitmap(bitmap, maxWidth, height, true)
        if (scaled !== bitmap) bitmap.recycle()
        return scaled
    }
}
