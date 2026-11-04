// 壁纸取色桥（第 231 轮，用户裁定「Material You 保留默认开，而且需要想办法让它真正取到壁纸色」）。
//
// 事实：`dynamic_color` 的 `DynamicColorBuilder` 在**没有 Material You 的机器**上
// 回调 null（EMUI/HarmonyOS、Android < 12、被 OEM 关掉的 ROM）⇒ App 一直渲染品牌蓝，
// "跟随壁纸"是个假开关。这里补一条**不依赖 Material You** 的取色通道：
//
//   ① `WallpaperManager.getWallpaperColors(FLAG_SYSTEM)`（API 27+）——
//      系统已经算好的壁纸主色，最省事也最"正确"；
//   ② 拿不到（返回 null / 抛异常 / OEM 阉割）就**自己读壁纸图**：
//      缩到 48px、按饱和度加权求平均色 ⇒ 一个能当 seed 的颜色；
//   ③ 都不行 ⇒ `source:"none"`，Dart 侧回退品牌蓝并**在界面上说清楚**。
//
// 三条纪律（同 DeviceModelBridge）：
//   ① **只读**：不申请权限、不写文件、不改设置；
//   ② 逐项 try/catch：拿不到就回 none，**不把异常抛给 Dart**；
//   ③ 原生侧不缓存（Dart 侧有 provider 缓存）。
package com.openviewai.synhub

import android.app.WallpaperManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.math.max

object WallpaperBridge {
    const val CHANNEL = "synhub/wallpaper"

    fun attach(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "seed" -> result.success(seed(app))
                    else -> result.notImplemented()
                }
            }
    }

    private fun seed(context: Context): Map<String, Any> {
        val out = HashMap<String, Any>()
        out["source"] = "none"
        out["seed"] = 0
        out["saturation"] = 0.0

        val wm = try {
            WallpaperManager.getInstance(context)
        } catch (t: Throwable) {
            out["error"] = t.javaClass.simpleName
            return out
        }

        // ① 系统算好的壁纸主色
        if (Build.VERSION.SDK_INT >= 27) {
            try {
                val colors = wm.getWallpaperColors(WallpaperManager.FLAG_SYSTEM)
                val primary = colors?.primaryColor
                if (primary != null) {
                    out["source"] = "wallpaperColors"
                    out["seed"] = primary.toArgb() and 0xFFFFFF
                    out["saturation"] = saturationOf(primary.toArgb())
                    out["sdkInt"] = Build.VERSION.SDK_INT
                    return out
                }
            } catch (t: Throwable) {
                out["colorsError"] = t.javaClass.simpleName
            }
        }

        // ② 自己读壁纸图，按饱和度加权求平均
        try {
            val drawable = wm.drawable
            if (drawable != null) {
                val w = max(drawable.intrinsicWidth, 1)
                val h = max(drawable.intrinsicHeight, 1)
                val ratio = 48f / max(w, h).toFloat()
                val bw = max((w * ratio).toInt(), 1)
                val bh = max((h * ratio).toInt(), 1)
                val bmp = Bitmap.createBitmap(bw, bh, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bmp)
                drawable.setBounds(0, 0, bw, bh)
                drawable.draw(canvas)
                val avg = weightedColor(bmp)
                bmp.recycle()
                if (avg != null) {
                    out["source"] = "bitmap"
                    out["seed"] = avg.first and 0xFFFFFF
                    out["saturation"] = avg.second
                    out["sdkInt"] = Build.VERSION.SDK_INT
                    return out
                }
                out["bitmapError"] = "noSaturatedPixel"
            } else {
                out["bitmapError"] = "noDrawable"
            }
        } catch (t: Throwable) {
            out["bitmapError"] = t.javaClass.simpleName
        }

        // ③ 系统主题色兜底（Android 12+ 的 `system_accent*` 就是 Material You 的调色板；
        //    **动态壁纸**（本机就是荣耀「OceanRealm」）拿不到壁纸图也拿不到 WallpaperColors，
        //    但系统仍可能定义了 accent ⇒ 这已经是"跟随系统主题/壁纸"的最接近的取值。
        val accent = systemAccent(context)
        if (accent != null) {
            out["source"] = "systemAccent"
            out["seed"] = accent.first and 0xFFFFFF
            out["saturation"] = accent.second
            out["sdkInt"] = Build.VERSION.SDK_INT
            android.util.Log.i(
                TAG,
                "seed source=systemAccent seed=#${(accent.first and 0xFFFFFF).toString(16)} sat=${accent.second}",
            )
            return out
        }

        android.util.Log.i(TAG, "seed source=none detail=$out")
        out["sdkInt"] = Build.VERSION.SDK_INT
        return out
    }

    private const val TAG = "WallpaperBridge"

    /// 读 Android 12+ 的 `system_accent1/2/3_500`。取**饱和度最高**的那个
    /// （`accent1` 常是灰蓝，`accent3` 才是壁纸里最跳的颜色）。
    private fun systemAccent(context: Context): Pair<Int, Double>? {
        if (Build.VERSION.SDK_INT < 31) return null
        var best: Pair<Int, Double>? = null
        for (name in listOf("system_accent1_500", "system_accent2_500", "system_accent3_500")) {
            val id = context.resources.getIdentifier(name, "color", "android")
            if (id == 0) continue
            val c = try {
                context.resources.getColor(id, null)
            } catch (t: Throwable) {
                continue
            }
            val sat = saturationOf(c)
            // 太灰的不算"壁纸色"
            if (sat < 0.08) continue
            if (best == null || sat > best!!.second) best = Pair(c, sat)
        }
        return best
    }

    /// 饱和度加权平均色 + 平均饱和度。权重 = 饱和度²，避开壁纸里大片灰/白。
    private fun weightedColor(bmp: Bitmap): Pair<Int, Double>? {
        val hsv = FloatArray(3)
        var r = 0.0
        var g = 0.0
        var b = 0.0
        var wsum = 0.0
        var ssum = 0.0
        var n = 0
        for (y in 0 until bmp.height) {
            for (x in 0 until bmp.width) {
                val c = bmp.getPixel(x, y)
                val a = Color.alpha(c)
                if (a < 128) continue
                Color.colorToHSV(c, hsv)
                val s = hsv[1].toDouble()
                val v = hsv[2].toDouble()
                // 太暗/太亮的像素对"取色"没意义（黑边、白底、纯黑壁纸）
                if (v < 0.08 || v > 0.98) continue
                val w = s * s
                if (w <= 0.0) continue
                r += Color.red(c) * w
                g += Color.green(c) * w
                b += Color.blue(c) * w
                wsum += w
                ssum += s
                n++
            }
        }
        if (wsum <= 0.0 || n == 0) return null
        val rr = (r / wsum).toInt().coerceIn(0, 255)
        val gg = (g / wsum).toInt().coerceIn(0, 255)
        val bb = (b / wsum).toInt().coerceIn(0, 255)
        return Pair(Color.rgb(rr, gg, bb), ssum / n)
    }

    private fun saturationOf(argb: Int): Double {
        val hsv = FloatArray(3)
        Color.colorToHSV(argb, hsv)
        return hsv[1].toDouble()
    }

    @Suppress("unused")
    private fun nearGray(argb: Int): Boolean = abs(saturationOf(argb)) < 0.05
}
