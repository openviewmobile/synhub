package com.openviewai.synhub

import android.content.Context
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionProvider
import com.google.android.gms.cast.CastMediaControlIntent

/**
 * C3 Chromecast：Cast SDK 的选项提供者（`AndroidManifest` 里按 SDK 要求注册）。
 *
 * 接收器用**默认媒体接收器**：官方 DSaudio 的 dex 里就是 `CC1AD845`，
 * 与 [CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID] 一致
 * —— 不是我们编的 id，是从官方 APK 里取出来的。
 */
class CastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions =
        CastOptions.Builder()
            .setReceiverApplicationId(
                CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID,
            )
            .build()

    override fun getAdditionalSessionProviders(context: Context): List<SessionProvider>? = null
}
