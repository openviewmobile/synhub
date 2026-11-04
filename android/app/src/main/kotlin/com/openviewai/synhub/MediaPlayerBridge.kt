// 自研 Android 播放器桥（**Media3 / ExoPlayer**，Android 官方库）。
//
// 为什么自己写而不是继续用 `video_player`：
//   * `video_player`（`video_player_android`，内部也是 Media3）只暴露
//     play/pause/seek/speed/尺寸 —— **不暴露**轨道选择、内封字幕、音量、
//     播放列表跳转，也不给 texture id；
//   * 项目规则是「协议/依赖问题就自研」：这里用的 `androidx.media3:*` 是 Google
//     官方库（不是第三方播放器内核），不引 `media_kit`/libmpv（12MB+/ABI + 许可证
//     争议）。
//
// 画面怎么进 Flutter：
//   用 `TextureRegistry.createTexture()` 建一张 **SurfaceTexture** 纹理，把它的
//   `Surface` 交给 ExoPlayer（`Player.setVideoSurface`），Dart 侧用
//   `Texture(textureId:)` 画。
//   ★ r296 真机根因：**不能**用 `createSurfaceProducer()` —— Flutter 3.47 的
//   `SurfaceProducer` 在 Android 上是 `ImageReader` 背板，华为 HiSilicon 硬解
//   在 configure 时会 `native_window_set_buffer_count` 而后者的 BufferQueue
//   回 `Invalid argument` ⇒ `Decoder init failed` ⇒ 真机所有视频都播不了。
//   详见字段 `textureEntry` 的注释与 `docs/device-verification.md` r296 条目。
//   **不是** PlatformView —— 所以 Flutter 的控制层叠在画面上没有任何混合合成
//   的层级/穿透问题。
//
// 字幕怎么显示：
//   内封文本轨由 Media3 解码，`Player.Listener.onCues(CueGroup)` 把**文本**经
//   EventChannel 发给 Dart，由 Dart 的 overlay 画（见 `media_player_view.dart`
//   的 `_SubtitleOverlay`）。没有用 `media3-ui` 的 `PlayerView`：视图树里根本
//   没有 PlayerView（画面是纹理），自绘 overlay 反而能跟 App 的排版一致。
//
// 音量：`ExoPlayer.setVolume`（**不动系统音量**）；静音只是把输出压到 0，
// 滑杆值仍然保留。
//
// 线程：MethodChannel / EventChannel 的回调都在主线程，ExoPlayer 也只在主线程
// 碰；位置更新用主线程 `Handler` 每 [TICK_MS] 毫秒发一次。
//
// 生命周期：`MainActivity.configureFlutterEngine` 注册（纯追加），
// `onDestroy` 里 detach。整个 App 同时只有一个播放器实例（页面也是单实例）。
package com.openviewai.synhub

import android.content.Context
import android.media.MediaCodecList
import android.media.MediaFormat
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.text.CueGroup
import androidx.media3.datasource.HttpDataSource
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManager
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import kotlin.math.roundToInt

object MediaPlayerBridge {
    const val CHANNEL = "synhub/player"
    const val EVENTS = "synhub/player_events"

    private const val TAG = "SynologyChatPlayer"

    /** 位置/状态事件间隔（250ms：字幕跟得上，又不至于把通道刷爆） */
    private const val TICK_MS = 250L

    /** 还不知道视频尺寸时给纹理一个默认大小（16:9），避免 0×0 纹理 */
    private const val DEFAULT_WIDTH = 1280
    private const val DEFAULT_HEIGHT = 720

    private var engine: FlutterEngine? = null
    private var player: ExoPlayer? = null

    /// ★ r296 真机根因修复：**不要**用 `renderer.createSurfaceProducer()` 的画面宿主。
    /// Flutter 3.47 的 `SurfaceProducer` 在 Android 上是 `ImageReader` 背板的 BufferQueue
    /// （真机日志：`BufferQueueProducer: [ImageReader-1280x720f22m7-…]`），而华为
    /// HiSilicon 硬解 `OMX.hisi.video.decoder.avc` 在 configure 阶段会调
    /// `native_window_set_buffer_count(6)` ⇒ ImageReader 背板回
    /// `IGraphicBufferProducer::setBufferCount(6) returned Invalid argument` ⇒
    /// `Failed to allocate buffers after transitioning to IDLE state` ⇒
    /// `Decoder init failed` ⇒ 真机上**任何视频都播不了**（H.264 mp4 也一样，
    /// 面板却显示"系统解码器不支持这个文件的编码"，误导性极强）。
    /// 换成 `createTexture()` 的 **SurfaceTexture** 背板（`video_player` 1.x 的老做法）后，
    /// 解码器可以正常改 buffer count。Dart 侧完全不用改：仍然拿 `textureId` 画 `Texture`。
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null

    /// 交给 ExoPlayer 的 `Surface`（由上面的 `SurfaceTexture` 包出来）。
    /// **必须自己持有并 release**：Surface 被 GC 掉画面就黑了。
    private var videoSurface: Surface? = null

    private var sink: EventChannel.EventSink? = null

    private val handler = Handler(Looper.getMainLooper())
    private var ticking = false

    // 通道侧要回读的状态（音量为 0–100 的整数，和 Dart 的 0–1 换算）
    private var volume = 100
    private var mutedValue = false
    private var speed = 1.0f
    private var aspect = "fit"
    private var videoWidth = 0
    private var videoHeight = 0
    private var lastError: String? = null

    // **纯追加**信号：视频渲染器真的出了第一帧。Dart 侧的"起播无进展"看门狗用它
    // 解除（真机 Theora 那种"没有解码器"既不出帧也不报错，只能靠这个区分）。
    // `onVideoSizeChanged` 只说明**格式**已知，不等于出了帧，所以两者分开。
    private var firstFrameRendered = false

    // ★ r437 DA91：画面证据的**归属下标** —— Dart 只接受 `*Index == 当前条目` 的证据。
    // 证据是条目级事实：换集时**不清**标志（清了就再也回不来，Media3 每条只回调一次
    // `onRenderedFirstFrame`），改由下标自然失效。
    private var firstFrameIndex = -1
    private var sizeIndex = -1

    // ★ r437 DA91：状态事件序号。`send()` 在非主线程走 `handler.post` ⇒ 事件可能乱序
    // 到达；Dart 只认更新的那一拍。
    private var emitSeq = 0

    private val ticker = object : Runnable {
        override fun run() {
            if (!ticking) return
            emitState()
            handler.postDelayed(this, TICK_MS)
        }
    }

    fun attach(context: Context, flutterEngine: FlutterEngine) {
        engine = flutterEngine
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "create" -> result.success(create(context))
                        "load" -> result.success(
                            load(
                                urls = call.argument<List<String>>("urls") ?: emptyList(),
                                index = (call.argument<Number>("index") ?: 0).toInt(),
                                autoplay = call.argument<Boolean>("autoplay") ?: false,
                                volumeArg = (call.argument<Number>("volume") ?: 1.0).toDouble(),
                                mutedArg = call.argument<Boolean>("muted") ?: false,
                                speedArg = (call.argument<Number>("speed") ?: 1.0).toDouble(),
                                aspectArg = call.argument<String>("aspect") ?: "fit",
                            ),
                        )
                        // ★ 第 259 轮真机缺陷修复：把 Dart 侧已采纳的 TLS 政策
                        // （自签 / 域名不匹配 / 首连信任指纹）同步给**原生媒体栈**。
                        // 不装它，真机上"能列目录、能看缩略图，一点视频就
                        // SSLPeerUnverifiedException"（见 setTlsPolicy 的注释）。
                        "setTlsPolicy" -> {
                            setTlsPolicy(
                                host = call.argument<String>("host"),
                                fingerprint = call.argument<String>("fingerprint"),
                            )
                            result.success(true)
                        }
                        "play" -> {
                            // ★ 第 295 轮：ExoPlayer 处于 STATE_ENDED 时 `play()` 是 no-op
                            // ⇒ 真机上"播到结尾后按播放键没反应"（位置冻住、无错误）。
                            // 先回到起点再播；Dart 侧也已做对称保护。
                            player?.let { p ->
                                if (p.playbackState ==
                                    androidx.media3.common.Player.STATE_ENDED
                                ) {
                                    p.seekTo(0)
                                }
                                p.play()
                            }
                            result.success(true)
                        }
                        "pause" -> {
                            player?.pause()
                            result.success(true)
                        }
                        "seekTo" -> {
                            val ms = (call.argument<Number>("positionMs") ?: 0).toLong()
                            seekTo(ms)
                            result.success(true)
                        }
                        "setSpeed" -> {
                            speed = ((call.argument<Number>("speed") ?: 1.0).toFloat())
                            player?.playbackParameters = PlaybackParameters(speed)
                            emitState()
                            result.success(true)
                        }
                        "setVolume" -> {
                            volume = (((call.argument<Number>("volume") ?: 1.0).toDouble()) * 100)
                                .roundToInt()
                                .coerceIn(0, 100)
                            player?.volume = volume / 100f
                            if (volume > 0 && mutedValue) {
                                mutedValue = false
                                player?.volume = volume / 100f
                            }
                            emitState()
                            result.success(true)
                        }
                        "setMuted" -> {
                            mutedValue = call.argument<Boolean>("muted") ?: false
                            player?.volume = if (mutedValue) 0f else volume / 100f
                            emitState()
                            result.success(true)
                        }
                        "next" -> {
                            player?.seekToNextMediaItem()
                            result.success(true)
                        }
                        "previous" -> {
                            player?.seekToPreviousMediaItem()
                            result.success(true)
                        }
                        "selectTrack" -> {
                            selectTrack(
                                kind = call.argument<String>("kind") ?: "audio",
                                id = call.argument<String>("id"),
                            )
                            result.success(true)
                        }
                        "setAspectMode" -> {
                            // 画面比例由 Dart 侧的 FittedBox 应用（画面是纹理，
                            // 原生没有 AspectRatioFrameLayout 可调）；这里只回读状态
                            aspect = call.argument<String>("aspect") ?: "fit"
                            emitState()
                            result.success(true)
                        }
                        "dispose" -> {
                            releasePlayer()
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "原生播放器调用失败（${call.method}）：${e.message}")
                    result.error("player_error", e.message ?: "player error", null)
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS)
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                        sink = events
                        emitState()
                        emitTracks()
                    }

                    override fun onCancel(arguments: Any?) {
                        sink = null
                    }
                },
            )
    }

    fun detach() {
        releasePlayer()
        sink = null
        engine = null
    }

    // ------------------------------------------------- TLS 政策（真机缺陷修复）

    /**
     * 把 Dart 侧（`DioFactory` + 首连信任库）已经采纳的 TLS 政策**同步给原生媒体栈**。
     *
     * ## 为什么必须有这一步（2026-09-26 真机实测）
     *
     * Android 上 `ExoPlayer`（本文件）与 `just_audio`（音频）**都**建在
     * `HttpURLConnection`（Media3 `DefaultHttpDataSource`）之上，用的是
     * **平台默认信任链 + 严格主机名校验**；而本 App 的 Dart HTTP 栈本来就按
     * `DioFactory` 的政策放行"自签 / 域名不匹配"。两边政策不一致，真机表现：
     * 目录能列、缩略图能看（走 Dart），一点开视频/音频就
     * ```
     * SSLPeerUnverifiedException: Hostname nas.example.com not verified
     *   DN: CN=nas.example.com subjectAltNames: [*.nas.example.com]
     * ERROR_CODE_IO_NETWORK_CONNECTION_FAILED(2001)
     * ```
     * —— 证书链其实是**受信任**的，挂的只是"用 IP 访问、证书签的是域名"。
     *
     * ## 政策（**窄**，只对**我们自己的那台 NAS 主机**生效）
     *
     * * `host` 精确匹配 → 主机名校验放行，**证书链仍由系统 CA 校验**
     *   （不装自定义 TrustManager，除非下面给了指纹）；
     * * `fingerprint` 非空 → 额外钉住**首连信任库里那一枚**证书指纹
     *   （自签证书场景；与 Dart `TrustStore` 同一枚 SHA-256 大写十六进制）；
     * * `host == null` → **还原**成平台默认（登出 / 切服务器 / 断连时调用）。
     *
     * ## 影响面
     *
     * 只影响 `HttpURLConnection` 这一类调用方（Dart 自己的网络栈是独立的
     * BoringSSL，Flutter 插件的 OkHttp3 用自己的 SSL 工厂，都不受影响）；
     * 对非目标主机一律委托给原验证器 / 原信任链。
     */
    private var tlsPolicyInstalled = false
    private var originalHostnameVerifier: HostnameVerifier? = null
    private var originalSslSocketFactory: SSLSocketFactory? = null
    private var tlsHost: String? = null
    private var tlsFingerprint: String? = null

    private fun setTlsPolicy(host: String?, fingerprint: String?) {
        if (!tlsPolicyInstalled) {
            originalHostnameVerifier = HttpsURLConnection.getDefaultHostnameVerifier()
            originalSslSocketFactory = HttpsURLConnection.getDefaultSSLSocketFactory()
            tlsPolicyInstalled = true
        }
        tlsHost = host
        tlsFingerprint = fingerprint
        val originalVerifier = originalHostnameVerifier
        if (host == null) {
            originalVerifier?.let { HttpsURLConnection.setDefaultHostnameVerifier(it) }
            originalSslSocketFactory?.let {
                HttpsURLConnection.setDefaultSSLSocketFactory(it)
            }
            Log.i(TAG, "TLS 政策：已还原平台默认")
            return
        }
        HttpsURLConnection.setDefaultHostnameVerifier { hostname, session ->
            if (hostname == host) {
                true
            } else {
                (originalVerifier ?: HttpsURLConnection.getDefaultHostnameVerifier())
                    .verify(hostname, session)
            }
        }
        if (fingerprint.isNullOrBlank()) {
            // 没给指纹 ⇒ **不碰信任链**（证书链照旧由系统 CA 校验）
            originalSslSocketFactory?.let {
                HttpsURLConnection.setDefaultSSLSocketFactory(it)
            }
            Log.i(TAG, "TLS 政策：主机名校验放宽（仅 $host），信任链不变")
            return
        }
        try {
            val ctx = SSLContext.getInstance("TLS")
            ctx.init(
                null,
                arrayOf<TrustManager>(PinnedTrustManager(fingerprint)),
                SecureRandom(),
            )
            HttpsURLConnection.setDefaultSSLSocketFactory(ctx.socketFactory)
            Log.i(TAG, "TLS 政策：主机名校验放宽 + 指纹钉住（仅 $host）")
        } catch (e: Exception) {
            Log.w(TAG, "TLS 政策：指纹固定装置没装上，退回系统信任链（${e.javaClass.simpleName}）")
            originalSslSocketFactory?.let {
                HttpsURLConnection.setDefaultSSLSocketFactory(it)
            }
        }
    }

    /**
     * 只在"系统信任链判定失败"时，才按**首连信任库里那一枚指纹**放行。
     * 系统能验过的证书一切照旧（不因为装了它而变松）。
     */
    private class PinnedTrustManager(private val pinned: String) : X509TrustManager {
        private val delegate: X509TrustManager = defaultTrustManager()

        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) =
            delegate.checkClientTrusted(chain, authType)

        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
            try {
                delegate.checkServerTrusted(chain, authType)
                return
            } catch (e: CertificateException) {
                if (chain.isNotEmpty() && sha256Hex(chain[0].encoded).equals(pinned, true)) return
                throw e
            }
        }

        override fun getAcceptedIssuers(): Array<X509Certificate> = delegate.acceptedIssuers

        private fun defaultTrustManager(): X509TrustManager {
            val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
            tmf.init(null as KeyStore?)
            return tmf.trustManagers.filterIsInstance<X509TrustManager>().first()
        }

        private fun sha256Hex(der: ByteArray): String {
            val d = MessageDigest.getInstance("SHA-256").digest(der)
            val sb = StringBuilder(d.size * 2)
            for (b in d) {
                val v = b.toInt() and 0xff
                sb.append(HEX[v ushr 4]).append(HEX[v and 0x0f])
            }
            return sb.toString()
        }

        private companion object {
            const val HEX = "0123456789ABCDEF"
        }
    }

    // --------------------------------------------------------------- 创建

    private fun create(context: Context): Long {
        releasePlayer()
        val flutterEngine = engine ?: error("FlutterEngine 还没 attach")
        // ★ r296：SurfaceTexture 背板（见字段注释里的真机根因）。
        // 引擎里这个 API 叫 `createSurfaceTexture()`（返回 `SurfaceTextureEntry`；
        // 旧的 `createTexture()` 在本版引擎里已经没有，`createSurfaceProducer()`
        // 才是 ImageReader 那条路）。`SurfaceTexture` 由 Flutter 直接当纹理渲染，
        // 我们自己包一层 `Surface` 交给 ExoPlayer —— 这条路径没有
        // `SurfaceProducer.Callback`（Surface 是我们自己持有的，生命周期可控）。
        val entry = flutterEngine.renderer.createSurfaceTexture()
        try {
            entry.surfaceTexture().setDefaultBufferSize(DEFAULT_WIDTH, DEFAULT_HEIGHT)
        } catch (e: Exception) {
            Log.w(TAG, "设置初始纹理尺寸失败：${e.message}")
        }
        val s = Surface(entry.surfaceTexture())
        textureEntry = entry
        videoSurface = s
        videoWidth = 0
        videoHeight = 0
        lastError = null
        firstFrameRendered = false
        firstFrameIndex = -1
        sizeIndex = -1
        val exo = ExoPlayer.Builder(context.applicationContext).build()
        exo.setVideoSurface(s)
        exo.addListener(listener)
        player = exo
        return entry.id()
    }

    // --------------------------------------------------------------- 载入

    private fun load(
        urls: List<String>,
        index: Int,
        autoplay: Boolean,
        volumeArg: Double,
        mutedArg: Boolean,
        speedArg: Double,
        aspectArg: String,
    ): Boolean {
        val exo = player ?: return false
        if (urls.isEmpty()) return false
        // 换文件重试时把上一次的错误/首帧状态清掉，否则面板会一直挂着、看门狗
        // 也会拿上一集的尺寸当"已出画面"。
        lastError = null
        firstFrameRendered = false
        firstFrameIndex = -1
        sizeIndex = -1
        videoWidth = 0
        videoHeight = 0
        val items = urls.map { MediaItem.fromUri(Uri.parse(it)) }
        // 「取流诊断」（**低噪声、可保留、绝不含凭据**）：每次载入每个 URL 打印一行，
        // 只列**白名单查询参数** + `_sid`/`SynoToken` 的**有无**。
        // 为什么要它：R5 真机上相册视频起播 58–85 ms 就 `Source error`，而当时
        // App 不打印取流形态、宿主也拿不到凭据，于是无法判断是"URL 形态不对"
        // 还是"服务端拒绝"（docs/media-streaming-diagnosis.md §2）。
        urls.forEachIndexed { i, u -> Log.i(TAG, "载入 media[$i] ${describeMediaUrl(u)}") }
        volume = (volumeArg * 100).roundToInt().coerceIn(0, 100)
        mutedValue = mutedArg
        speed = speedArg.toFloat()
        aspect = aspectArg
        exo.setMediaItems(items, index.coerceIn(0, items.size - 1), C.TIME_UNSET)
        exo.volume = if (mutedValue) 0f else volume / 100f
        exo.playbackParameters = PlaybackParameters(speed)
        exo.setPlayWhenReady(autoplay)
        exo.prepare()
        startTicking()
        emitState()
        emitTracks()
        return true
    }

    private fun seekTo(ms: Long) {
        val exo = player ?: return
        val total = exo.duration
        var target = ms
        if (target < 0) target = 0
        if (total != C.TIME_UNSET && total > 0 && target > total) target = total
        exo.seekTo(target)
        emitState()
    }

    // --------------------------------------------------------------- 轨道

    private fun selectTrack(kind: String, id: String?) {
        val exo = player ?: return
        val type = if (kind == "subtitle") C.TRACK_TYPE_TEXT else C.TRACK_TYPE_AUDIO
        val builder = exo.trackSelectionParameters.buildUpon()
        if (id.isNullOrEmpty()) {
            builder.clearOverridesOfType(type)
            builder.setTrackTypeDisabled(type, true)
        } else {
            val parsed = parseTrackId(id) ?: return
            val groups = exo.currentTracks.groups
            if (parsed.second !in groups.indices) return
            val group = groups[parsed.second]
            if (group.type != type) return
            builder.setTrackTypeDisabled(type, false)
            builder.setOverrideForType(
                TrackSelectionOverride(group.mediaTrackGroup, parsed.third),
            )
        }
        exo.trackSelectionParameters = builder.build()
        emitTracks()
    }

    /** `audio:0:1` → (kind, groupIndex, trackIndex)；形状不对 → null */
    private fun parseTrackId(id: String): Triple<String, Int, Int>? {
        val parts = id.split(":")
        if (parts.size != 3) return null
        val group = parts[1].toIntOrNull() ?: return null
        val track = parts[2].toIntOrNull() ?: return null
        return Triple(parts[0], group, track)
    }

    private fun trackMap(
        kind: String,
        groupIndex: Int,
        trackIndex: Int,
        group: Tracks.Group,
    ): Map<String, Any?> {
        val format = group.getTrackFormat(trackIndex)
        return mapOf(
            "id" to "$kind:$groupIndex:$trackIndex",
            "kind" to kind,
            "label" to (format.label ?: ""),
            "language" to (format.language ?: ""),
            "codec" to (format.codecs ?: format.sampleMimeType ?: ""),
            "channels" to format.channelCount,
            "default" to (format.selectionFlags and C.SELECTION_FLAG_DEFAULT != 0),
            "selected" to group.isTrackSelected(trackIndex),
            // ★ r654：这一条**本机能不能解码**。判据来自 Media3 的
            //   `Tracks.Group.isTrackSupported()`（渲染器握手结果），不是猜编码。
            // ★★★ r655 修 `DA267`：Media3 的"支持"里混了 **SPDIF 直通** ——
            //   AC3/EAC3/TrueHD 这类编码，平台会报"支持"（能原样丢给 HDMI 功放），
            //   但手机自己没有把它变成 PCM 的解码器。真机读数（HONOR LGE-AN10）：
            //   `audio/ac3` 这条 `isTrackSupported == true`、**没有**"本机不支持"后缀，
            //   可 `dumpsys media.audio_flinger` 里 `Tracks of which 0 are active`、
            //   logcat 只有 `avc.decoder` 在跑 ⇒ **有画面、零声音、零提示**，
            //   比"报错"更坏。所以这里再向系统要一次**真解码器**
            //   （`MediaCodecList.findDecoderForFormat`，它不含直通路径）。
            "supported" to (group.isTrackSupported(trackIndex) && hasRealDecoder(format)),
            "group" to groupIndex,
            "index" to trackIndex,
        )
    }

    /**
     * 系统里**真的**有把这条轨道解成 PCM 的解码器吗？
     *
     * 只问 `MediaCodecList.REGULAR_CODECS`（不走 `MediaCodec.createDecoderByType`，
     * 那个对直通 MIME 也会成功）。查不到、或这机器上抛异常 ⇒ 返回 `true`
     * （**判不了就别误报"不支持"**，宁可维持 Media3 的判断）。
     */
    private fun hasRealDecoder(format: androidx.media3.common.Format): Boolean {
        val mime = format.sampleMimeType ?: return true
        if (!androidx.media3.common.MimeTypes.isAudio(mime)) return true
        return try {
            val probe = MediaFormat().apply { setString(MediaFormat.KEY_MIME, mime) }
            val found = MediaCodecList(MediaCodecList.REGULAR_CODECS)
                .findDecoderForFormat(probe)
            Log.i(TAG, "音轨能力探测 mime=$mime 真解码器=${found ?: "无"}")
            found != null
        } catch (t: Throwable) {
            Log.w(TAG, "hasRealDecoder($mime) 探测失败，按支持处理: ${t.message}")
            true
        }
    }

    private fun emitTracks() {
        val exo = player
        val audio = mutableListOf<Map<String, Any?>>()
        val subtitles = mutableListOf<Map<String, Any?>>()
        // ★ r438 `DA92`：本条**有没有视频轨**是"确定事实"，与"还没等到首帧"不是一回事。
        // 只有音轨的条目（例如音乐被当成视频来源打开）永远不会有画面 ⇒ Dart 侧据此
        // **当轮**定性，不必等它播到结尾（既有的"时钟在推 ⇒ 再看一轮"取舍只适用于
        // 可能还有画面的条目）。同时带上条目下标，免得旧条目的 tracks 顶替新条目。
        var videoCount = 0
        if (exo != null) {
            exo.currentTracks.groups.forEachIndexed { groupIndex, group ->
                val kind = when (group.type) {
                    C.TRACK_TYPE_AUDIO -> "audio"
                    C.TRACK_TYPE_TEXT -> "subtitle"
                    else -> null
                }
                if (group.type == C.TRACK_TYPE_VIDEO) videoCount += group.length
                if (kind != null) {
                    for (trackIndex in 0 until group.length) {
                        val map = trackMap(kind, groupIndex, trackIndex, group)
                        if (kind == "audio") audio.add(map) else subtitles.add(map)
                    }
                }
            }
        }
        send(
            mapOf(
                "kind" to "tracks",
                "audio" to audio,
                "subtitle" to subtitles,
                "videoCount" to videoCount,
                "index" to (exo?.currentMediaItemIndex ?: 0),
            ),
        )
    }

    private fun emitCues(cueGroup: CueGroup) {
        val text = cueGroup.cues
            .mapNotNull { it.text?.toString() }
            .filter { it.isNotBlank() }
            .joinToString("\n")
        send(mapOf("kind" to "cues", "text" to text))
    }

    // --------------------------------------------------------------- 事件

    private val listener = object : Player.Listener {
        override fun onVideoSizeChanged(videoSize: VideoSize) {
            if (videoSize.width > 0 && videoSize.height > 0) {
                videoWidth = videoSize.width
                videoHeight = videoSize.height
                // 渲染器会把 unappliedRotationDegrees 转正后再出帧 → 纹理尺寸
                // 要按转正后的宽高设（与 video_player 的做法一致）
                val rotated = videoSize.unappliedRotationDegrees == 90 ||
                    videoSize.unappliedRotationDegrees == 270
                val w = if (rotated) videoHeight else videoWidth
                val h = if (rotated) videoWidth else videoHeight
                try {
                    // ★ r296：SurfaceTexture 背板的尺寸用 `setDefaultBufferSize`
                    // 设（老 API），不是 `SurfaceProducer.setSize`。
                    textureEntry?.surfaceTexture()?.setDefaultBufferSize(w, h)
                } catch (e: Exception) {
                    Log.w(TAG, "设置纹理尺寸失败：${e.message}")
                }
                sizeIndex = player?.currentMediaItemIndex ?: 0
            }
            emitState()
        }

        override fun onTracksChanged(tracks: Tracks) {
            emitTracks()
        }

        // 视频**真的出了第一帧**（格式已知 ≠ 出帧；Theora 这种没解码器的情形
        // 既不出帧也不报错，Dart 侧的看门狗就靠这个信号解除）。
        override fun onRenderedFirstFrame() {
            firstFrameRendered = true
            firstFrameIndex = player?.currentMediaItemIndex ?: 0
            emitState()
        }

        override fun onCues(cueGroup: CueGroup) {
            emitCues(cueGroup)
        }

        override fun onPlayerError(error: PlaybackException) {
            // 错误串要能让 Dart 侧区分**三类失败**（R5 真机把它们混成一句
            // "播放失败"）：解码器不支持 / 网络连不上 / 服务端拒绝取流。
            val summary = describePlaybackError(error)
            lastError = summary
            Log.w(TAG, "播放失败：$summary")
            emitState()
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            emitState()
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            emitState()
        }

        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            // 换集后旧字幕文本必须清掉，否则会短暂显示上一集的字幕；
            // 画面状态同理（Dart 侧的看门狗不能用上一集的尺寸/首帧当"已出画面"）
            send(mapOf("kind" to "cues", "text" to ""))
            // ★ r437 DA91：只清**格式**（尺寸/归属），**不清** `firstFrameRendered` ——
            // 这一拍可能**晚于**新条目的 `onRenderedFirstFrame`（r431 真机现场：画面在播
            // 却挂"播不了"）。清了就再也回不来（Media3 每条只回调一次首帧）。
            videoWidth = 0
            videoHeight = 0
            sizeIndex = -1
            emitState()
        }
    }

    private fun startTicking() {
        if (ticking) return
        ticking = true
        handler.post(ticker)
    }

    private fun stopTicking() {
        ticking = false
        handler.removeCallbacks(ticker)
    }

    private fun emitState() {
        val exo = player
        val durationMs = exo?.duration?.takeIf { it != C.TIME_UNSET && it > 0 } ?: 0L
        send(
            mapOf(
                "kind" to "state",
                "positionMs" to (exo?.currentPosition ?: 0L),
                "durationMs" to durationMs,
                "playing" to (exo?.isPlaying == true),
                "ready" to (exo?.playbackState == Player.STATE_READY),
                "buffering" to (exo?.playbackState == Player.STATE_BUFFERING),
                "ended" to (exo?.playbackState == Player.STATE_ENDED),
                "index" to (exo?.currentMediaItemIndex ?: 0),
                "count" to (exo?.mediaItemCount ?: 0),
                "volume" to volume,
                "muted" to mutedValue,
                "speed" to speed.toDouble(),
                "aspect" to aspect,
                "videoWidth" to videoWidth,
                "videoHeight" to videoHeight,
                "firstFrame" to firstFrameRendered,
                "firstFrameIndex" to firstFrameIndex,
                "sizeIndex" to sizeIndex,
                "seq" to (++emitSeq),
                "error" to (lastError ?: ""),
            ),
        )
    }

    private fun send(payload: Map<String, Any?>) {
        val events = sink ?: return
        if (Looper.myLooper() == Looper.getMainLooper()) {
            events.success(payload)
        } else {
            handler.post { events.success(payload) }
        }
    }

    private fun releasePlayer() {
        stopTicking()
        val exo = player
        player = null
        try {
            exo?.removeListener(listener)
            exo?.release()
        } catch (e: Exception) {
            Log.w(TAG, "释放 ExoPlayer 失败：${e.message}")
        }
        try {
            // ★ r296：顺序不能反 —— 先解绑/释放 Surface，再释放纹理条目。
            videoSurface?.release()
        } catch (e: Exception) {
            Log.w(TAG, "释放画面 Surface 失败：${e.message}")
        }
        videoSurface = null
        try {
            textureEntry?.release()
        } catch (e: Exception) {
            Log.w(TAG, "释放纹理失败：${e.message}")
        }
        textureEntry = null
        videoWidth = 0
        videoHeight = 0
        firstFrameRendered = false
        firstFrameIndex = -1
        sizeIndex = -1
        lastError = null
    }

    // ------------------------------------------------------------ 取流诊断
    //
    // 硬约束（见 docs/media-streaming-diagnosis.md §3）：
    //   * **绝不**打印 `_sid` / `SynoToken` / 密码 / 完整 URL 的敏感段；
    //   * 只输出**结构化摘要**：白名单查询参数、状态码、内容类型、长度、正文种类；
    //   * 低噪声：载入每个 URL 一行 `Log.i`，每次播放错误一条 `Log.w`（可保留）。

    /** 媒体 URL 的**白名单参数**（这些不是凭据，服务端就是靠它们选流）。 */
    private val diagnosticParams = setOf(
        "api", "method", "version", "id", "type", "quality", "unit_id",
        "item_id", "size", "cache_key", "use_mov", "mode",
    )

    /**
     * 把交给 Media3 的那条 URL 描述成一行**不含凭据**的诊断串。
     *
     * 例：`api=SYNO.Foto.Streaming method=streaming version=2 id=9317 type=item sid=yes token=yes`
     * 以前这里只有 `id`、没有 `type` —— R5 真机的相册取流就这么错了一整轮却看不见。
     */
    private fun describeMediaUrl(raw: String): String {
        val uri = try {
            Uri.parse(raw)
        } catch (e: Exception) {
            return "<无法解析的 URL>"
        }
        val parts = mutableListOf<String>()
        for (key in diagnosticParams) {
            val v = uri.getQueryParameter(key) ?: continue
            parts.add("$key=$v")
        }
        parts.add("sid=" + if (uri.getQueryParameter("_sid").isNullOrEmpty()) "no" else "yes")
        parts.add(
            "token=" +
                if (uri.getQueryParameter("SynoToken").isNullOrEmpty()) "no" else "yes",
        )
        // path 只报**最后一段**（`entry.cgi` / `stream.cgi`）：能看出走哪条通道，
        // 又不带出目录结构里的隐私信息。
        val last = uri.lastPathSegment?.substringAfterLast('/') ?: ""
        return (if (last.isEmpty()) parts else listOf("path=$last") + parts).joinToString(" ")
    }

    /**
     * `PlaybackException` → 一行可分类的错误摘要（**永不包含 URL 与凭据**）。
     *
     * Dart 侧 `classifyPlayerError` 靠这串区分"解码器不支持 / 网络连不上 /
     * 服务端拒绝取流"三件事；`InvalidResponseCodeException` 的 `responseCode` /
     * `headerFields` / `responseBody` 是 Media3 **公开字段**
     * （`media3-datasource` 的 `HttpDataSource$InvalidResponseCodeException`），
     * 所以 HTTP 状态码、内容类型、长度、正文种类都能拿到 —— 不需要自写 DataSource。
     * （Media3 对**响应头**没有公开回调，`DefaultHttpDataSource` 也不暴露
     * `getResponseHeaders()`；要更细只有自带 `DataSource` 包装，
     * 而 200 + JSON 错误体这种情形连异常都不会有 —— 见文档 §7 的边界。）
     */
    private fun describePlaybackError(error: PlaybackException): String {
        val parts = mutableListOf<String>()
        parts.add(error.errorCodeName + "(" + error.errorCode + ")")
        var cause: Throwable? = error
        var depth = 0
        while (cause != null && depth < 5) {
            val c = cause
            when (c) {
                is HttpDataSource.InvalidResponseCodeException -> {
                    parts.add("http=" + c.responseCode)
                    val ct = c.headerFields.entries
                        .firstOrNull { it.key.equals("Content-Type", ignoreCase = true) }
                        ?.value?.firstOrNull()
                    if (ct != null) parts.add("contentType=" + ct.take(80))
                    val cl = c.headerFields.entries
                        .firstOrNull { it.key.equals("Content-Length", ignoreCase = true) }
                        ?.value?.firstOrNull()
                    if (cl != null) parts.add("contentLength=" + cl.take(20))
                    // 重定向：Media3 默认跟随同协议重定向；这里只能看到"最终 3xx"
                    // （`setAllowCrossProtocolRedirects` 关闭时的跨协议跳转）。
                    if (c.responseCode in 300..399) parts.add("redirect=yes")
                    parts.add("body=" + sniffBodyKind(c.responseBody))
                }
                else -> parts.add(c.javaClass.simpleName)
            }
            val msg = c.message
            if (!msg.isNullOrBlank()) {
                val clean = scrubCredentials(msg)
                if (clean.isNotBlank()) parts.add(clean.take(120))
            }
            cause = c.cause
            depth++
        }
        return parts.joinToString(" | ")
    }

    /** 响应正文的**种类**（不打印正文本身）：HTML 登录页 / DSM JSON / 空 / 其它。 */
    private fun sniffBodyKind(body: ByteArray?): String {
        if (body == null || body.isEmpty()) return "empty"
        val head = String(body, 0, minOf(body.size, 256), Charsets.UTF_8)
            .trimStart().lowercase()
        return when {
            head.startsWith("<!doctype") || head.startsWith("<html") -> "html"
            head.startsWith("{") || head.startsWith("[") -> "json"
            else -> "other"
        }
    }

    /**
     * 抹掉可能混进异常文本里的凭据与 URL。
     *
     * `DataSpec.toString()` / `HttpDataSourceException` 的元凶链里**可能**带完整
     * URL（查询串里有 `_sid`、`SynoToken`）→ 一律替换成占位符，绝不落日志。
     */
    private fun scrubCredentials(text: String): String = text
        .replace(URL_REGEX, "<url>")
        .replace(SECRET_QUERY_REGEX, "$1<redacted>")

    private val URL_REGEX = Regex("""https?://\S+""", RegexOption.IGNORE_CASE)

    private val SECRET_QUERY_REGEX = Regex(
        """([?&](?:_sid|sid|SynoToken|syno_token|synotoken)=)[^&\s"']*""",
        RegexOption.IGNORE_CASE,
    )
}
