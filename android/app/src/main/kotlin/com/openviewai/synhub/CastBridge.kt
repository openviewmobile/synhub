package com.openviewai.synhub

import android.content.Context
import android.util.Log
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.mediarouter.media.MediaRouter
import com.google.android.gms.cast.CastDevice
import org.json.JSONObject

/**
 * C3 Chromecast：GMS Cast SDK → Dart。
 *
 * 通道：`synhub/cast`
 *  * `availability` → `{available:Boolean, devices:[{id,name}]}`
 *  * `connect`      → `{deviceId:String}`（deviceId = MediaRouter 的 route id）
 *  * `play`         → `{mediaUrl:String, positionSeconds:Int?}`
 *  * `disconnect`
 *
 * ⚠️ 没有 Google Play 服务 / 未选到设备时一律如实回 `available=false` 或 `false`，
 * **不假装投送成功**（Dart 侧 `AudioCastController` 有同样的约束）。
 */
object CastBridge {
    private const val TAG = "CastBridge"
    private const val CHANNEL = "synhub/cast"

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var castContext: CastContext? = null
    private var sessionListener: SessionManagerListener<CastSession>? = null

    fun attach(ctx: Context, engine: FlutterEngine) {
        context = ctx.applicationContext
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        try {
            castContext = CastContext.getSharedInstance(context!!)
        } catch (e: Throwable) {
            // 设备没有 Google Play 服务 → 保持 null，一切如实报"不可用"
            Log.w(TAG, "CastContext unavailable", e)
        }
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "availability" -> result.success(availability())
                "connect" -> {
                    val id = call.argument<String>("deviceId")
                    result.success(id != null && selectRoute(id))
                }
                "play" -> {
                    val url = call.argument<String>("mediaUrl")
                    val pos = call.argument<Int>("positionSeconds") ?: 0
                    result.success(url != null && load(url, pos))
                }
                "disconnect" -> {
                    endSession()
                    result.success(true)
                }
                // ↓↓↓ 照片投送（`urn:x-cast:com.synology.photos` 命名空间消息）。
                // 与音频的 availability/connect/play/disconnect 是**不同方法名**，
                // 同一条通道上互不影响。
                "photoCastAvailability" -> result.success(availability())
                "photoCastConnect" -> {
                    val id = call.argument<String>("deviceId")
                    result.success(id != null && selectRoute(id))
                }
                "photoCastSend" -> {
                    val ns = call.argument<String>("namespace")
                    val msg = call.argument<Map<String, Any?>>("message")
                    result.success(
                        ns != null && msg != null && sendNamespaceMessage(ns, msg),
                    )
                }
                "photoCastDisconnect" -> {
                    endSession()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        sessionListener?.let { l ->
            try {
                castContext?.sessionManager?.removeSessionManagerListener(l, CastSession::class.java)
            } catch (_: Throwable) {
            }
        }
        sessionListener = null
    }

    private fun availability(): Map<String, Any> {
        val ctx = context ?: return mapOf("available" to false)
        val cc = castContext ?: return mapOf("available" to false)
        try {
            val router = MediaRouter.getInstance(ctx)
            val devices = router.routes.mapNotNull { route ->
                val dev = CastDevice.getFromBundle(route.extras)
                    ?: return@mapNotNull null
                mapOf(
                    "id" to route.id,
                    "name" to (dev.friendlyName ?: route.name ?: route.id),
                )
            }
            // 即使当前没发现设备，只要 SDK 可用就算 available（否则界面永远禁用）
            return mapOf("available" to true, "devices" to devices)
        } catch (e: Throwable) {
            Log.w(TAG, "availability failed", e)
            return mapOf("available" to false)
        }
    }

    private fun selectRoute(routeId: String): Boolean {
        val ctx = context ?: return false
        return try {
            val router = MediaRouter.getInstance(ctx)
            val route = router.routes.firstOrNull { it.id == routeId } ?: return false
            router.selectRoute(route)
            true
        } catch (e: Throwable) {
            Log.w(TAG, "selectRoute failed", e)
            false
        }
    }

    private fun load(url: String, positionSeconds: Int): Boolean {
        return try {
            val session = castContext?.sessionManager?.currentCastSession ?: return false
            val client: RemoteMediaClient = session.remoteMediaClient ?: return false
            val info = MediaInfo.Builder(url)
                .setStreamType(MediaInfo.STREAM_TYPE_BUFFERED)
                .setContentType("audio/mpeg")
                .build()
            val request = MediaLoadRequestData.Builder()
                .setMediaInfo(info)
                .setAutoplay(true)
                .setCurrentTime(positionSeconds * 1000L)
                .build()
            client.load(request)
            true
        } catch (e: Throwable) {
            Log.w(TAG, "load failed", e)
            false
        }
    }

    /**
     * 往自定义命名空间发一条 JSON 消息（照片投送走这条）。
     *
     * 收不到会话 / SDK 不在 / 命名空间没注册 → `false`，**绝不假装发成功**。
     */
    private fun sendNamespaceMessage(ns: String, payload: Map<String, Any?>): Boolean {
        return try {
            val session = castContext?.sessionManager?.currentCastSession ?: return false
            val json = JSONObject(payload as Map<*, *>)
            // 该版本 GMS Cast 的重载是 `sendMessage(String, String)` ⇒ 送 JSON 文本
            session.sendMessage(ns, json.toString())
            true
        } catch (e: Throwable) {
            Log.w(TAG, "sendMessage failed", e)
            false
        }
    }

    private fun endSession() {
        try {
            castContext?.sessionManager?.endCurrentSession(true)
        } catch (e: Throwable) {
            Log.w(TAG, "endSession failed", e)
        }
    }
}
