package com.openviewai.synhub

import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 审计行 262：**聊天深链**（`synochat` / `synochats` / `synochatGuest` / `synochatsGuest`）。
 *
 * 与 `ShareIntentBridge` 同构：
 * 冷启动 / 前台各存一次待处理 intent 的 scheme + extras，
 * Dart 侧 `getPending` **取走即清**，并用 `onDeepLink` 提醒有新链接。
 *
 * ## 参数名为什么是 `address` / `account`
 * 逐字对齐官方 `com.synology.dschat` 的 `LoginActivity.fillInData`
 * （`LoginActivity.java:139-140` 取 `getIntent().getStringExtra("address")` /
 *  `getStringExtra("account")`）。
 *
 * ## 为什么**不**在这里处理 `guest`
 * 官方对**四条** scheme 一律 `mGuestBox.setChecked(true)`（`LoginActivity.java:145`，
 * baksmali 复核 `const/4 v4,0x1`）。但**访客登录属于审计行 261，本仓未实现**
 * （`SAS.Guest` 调用协议证据不足）⇒ 这里**只透传 scheme**，
 * 由 Dart 侧决定是否消费，**不在这里半途实现访客链路**。
 *
 * ## ⚠️ 不声明 `synology-chat://`
 * 那是官方 AppAuth 的 OAuth 回跳（receiver =
 * `net.openid.appauth.RedirectUriReceiverActivity`），
 * 本 App 没有 OIDC 登录，声明了只会造成误导。
 */
object DeepLinkBridge {
    private const val CHANNEL = "synhub/deep_link"

    /** 官方 SplashActivity 真机 dumpsys 实测的**四条** scheme（无 authority / path）。 */
    private val schemes =
        setOf("synochat", "synochats", "synochatGuest", "synochatsGuest")

    private var channel: MethodChannel? = null
    private var pending: Map<String, Any?>? = null

    fun attach(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    // 取走即清：同一条链接不会被消费两次
                    "getPending" -> {
                        result.success(pending)
                        pending = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun handleIntent(intent: Intent?) {
        val scheme = intent?.scheme ?: return
        if (scheme !in schemes) return
        pending = mapOf(
            "scheme" to scheme,
            "address" to intent.getStringExtra("address"),
            "account" to intent.getStringExtra("account"),
        )
        channel?.invokeMethod("onDeepLink", null)
    }
}
