package com.openviewai.synhub

import android.content.Context
import android.content.res.Configuration
import android.util.Log
import java.io.File
import java.util.Locale

/**
 * 「App 内语言」→ 原生文案（第 41 轮）。
 *
 * 背景：通知栏 / 前台服务 / 小组件这些文案由 Kotlin 生成，**不走 ARB**，
 * 于是出现"App 切英文、通知里还是中文"。Android 资源默认跟**系统语言**，
 * 所以这里按 App 自己的选择**造一个带该 Locale 的 Context**再去 getString。
 *
 * 语言来源：Dart 侧把用户选择镜像成 `files/app_locale.txt`
 * （见 `lib/src/core/settings/native_locale_mirror.dart`）——
 * 本仓设置存在 Drift 键值表里，原生读不到，且不为它新增依赖。
 * 读不到 / 为空 / `system` ⇒ **跟随系统**（返回原 Context，行为不变）。
 */
object AppLang {
    private const val TAG = "AppLang"
    private const val FILE_NAME = "app_locale.txt"

    fun rawTag(ctx: Context): String = try {
        val f = File(ctx.filesDir, FILE_NAME)
        if (f.exists()) f.readText().trim() else ""
    } catch (e: Exception) {
        Log.w(TAG, "读取 app_locale.txt 失败：${e.message}")
        ""
    }

    fun localized(ctx: Context): Context {
        val raw = rawTag(ctx)
        if (raw.isEmpty() || raw == "system") return ctx
        val locale = when {
            raw.startsWith("zh", ignoreCase = true) -> Locale.SIMPLIFIED_CHINESE
            raw.startsWith("en", ignoreCase = true) -> Locale.ENGLISH
            else -> return ctx
        }
        return try {
            val cfg = Configuration(ctx.resources.configuration)
            cfg.setLocale(locale)
            ctx.createConfigurationContext(cfg)
        } catch (e: Exception) {
            Log.w(TAG, "创建本地化 Context 失败：${e.message}")
            ctx
        }
    }

    /** 取本地化字符串（读不到资源时回退到默认资源，绝不崩）。 */
    fun s(ctx: Context, resId: Int, vararg args: Any): String = try {
        val c = localized(ctx)
        if (args.isEmpty()) c.getString(resId) else c.getString(resId, *args)
    } catch (e: Exception) {
        Log.w(TAG, "取本地化字符串失败：${e.message}")
        ""
    }
}
