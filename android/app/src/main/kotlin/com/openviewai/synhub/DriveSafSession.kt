// ★★★ ③Drive **D66「SAF provider 自登录 DSM」** 的 Kotlin 半边 —— 第 246 轮。
//
// ## 官方对照
// 官方 `SynologyDrive 3.9.0-1113` 的 `DriveDocumentsProvider` 在**冷启动**
// （系统文件选择器把它拉起、App 主界面没开）时也能开云端文件：它把自己的
// SDK 塞进 provider，provider 自己登录 DSM、自己下载、再把文件句柄交出去。
//
// ## 本实现
// `DriveDocumentsProvider.openDocument` 在"本地没有副本"时调用本对象：
//   1. 从 SharedPreferences 取凭据（**密码用 Android Keystore 的 AES/GCM 加密**）；
//   2. sid 还有效就用它；过期/没有就 `SYNO.API.Auth login v6` 重新登录
//      （与 Dart 侧 `cgi_encryption`/登录用的**同一个接口**，但这里不走加密
//      通道 —— provider 是原生进程、没有 Dart 的 RSA 公钥流程；`passwd` 直接
//      发在 TLS 上，与官方 SDK 的做法一致）；
//   3. `SYNO.SynologyDrive.Files download v2` 把文件下到
//      `cacheDir/saf_ondemand/<fileId>_<名字>`（**与 Dart 侧同一目录约定**，
//      见 `lib/src/features/files/drive_open_on_demand.dart` 的
//      `kSafOnDemandDirName` / `safOnDemandFileName`）；
//   4. 返回落盘路径。
//
// ## 真机未验（如实标注）
// 本仓不跑 Gradle、没有设备 ⇒ 这段 Kotlin **没有真机证据**：
//   * 登录/下载的网络路径、Keystore 加解密、provider 冷启动时序都未在真机跑过；
//   * Dart 侧用 **Mock Server** 验证了同一套协议（`drive_open_on_demand_test.dart`），
//     `test/drive_saf_session_contract_test.dart` 用**读源码**的方式钉住
//     两边的通道名/键/接口版本，防止"改了一边忘了另一边"。
package com.openviewai.synhub

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

object DriveSafSession {

    /** 通道名（Dart 侧 `DriveSafSessionBridge.channel` 必须一致）。 */
    const val CHANNEL = "synhub/drive_saf"

    /** SharedPreferences 名与键（契约测试会钉住这些字符串）。 */
    const val PREFS = "drive_saf"
    const val KEY_BASE_URL = "base_url"
    const val KEY_USERNAME = "username"
    const val KEY_PASSWORD_ENC = "password_enc"
    const val KEY_OTP = "otp"
    const val KEY_DEVICE_ID = "device_id"
    const val KEY_SID = "sid"
    const val KEY_SID_AT = "sid_at"
    const val KEY_ON_DEMAND = "on_demand"

    /** 与 Dart 侧 `kSafOnDemandDirName` 一致。 */
    const val ONDEMAND_DIR = "saf_ondemand"

    /** Keystore 别名（只存自己生成的 AES 密钥，不上传）。 */
    private const val KEY_ALIAS = "synhub_drive_saf"
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val GCM_TAG_BITS = 128

    /** sid 保鲜期：官方会话默认 7 天，这里保守取 20 小时再重登。 */
    private const val SID_TTL_MS = 20L * 60 * 60 * 1000

    /** Drive 的登录 session 名（官方 `SynologyDrive`）。 */
    private const val SESSION_NAME = "SynologyDrive"

    // ───────── 凭据存取 ─────────

    fun save(
        ctx: Context,
        baseUrl: String,
        username: String,
        password: String,
        otp: String,
        deviceId: String,
        onDemand: Boolean,
    ) {
        val sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        sp.putString(KEY_BASE_URL, baseUrl)
        sp.putString(KEY_USERNAME, username)
        sp.putString(KEY_OTP, otp)
        sp.putString(KEY_DEVICE_ID, deviceId)
        sp.putString(KEY_PASSWORD_ENC, encrypt(password))
        sp.putBoolean(KEY_ON_DEMAND, onDemand)
        // 换了凭据 ⇒ 旧 sid 作废
        sp.remove(KEY_SID)
        sp.remove(KEY_SID_AT)
        sp.apply()
    }

    fun clear(ctx: Context) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
        File(ctx.cacheDir, ONDEMAND_DIR).deleteRecursively()
    }

    fun setOnDemand(ctx: Context, on: Boolean) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_ON_DEMAND, on).apply()
    }

    fun status(ctx: Context): Map<String, Any> {
        val sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return mapOf(
            "configured" to (sp.getString(KEY_BASE_URL, "").orEmpty().isNotEmpty() &&
                sp.getString(KEY_USERNAME, "").orEmpty().isNotEmpty()),
            "onDemand" to sp.getBoolean(KEY_ON_DEMAND, false),
            "baseUrl" to sp.getString(KEY_BASE_URL, "").orEmpty(),
            "username" to sp.getString(KEY_USERNAME, "").orEmpty(),
            "hasSid" to !sp.getString(KEY_SID, "").orEmpty().isEmpty(),
            "cachedBytes" to onDemandCacheBytes(ctx),
        )
    }

    // ───────── 登录 / 下载 ─────────

    /** 拿一个可用 sid：缓存有效就用缓存，否则重新登录。失败抛 IOException。 */
    @Throws(Exception::class)
    fun sid(ctx: Context, forceLogin: Boolean = false): String {
        val sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val cached = sp.getString(KEY_SID, "").orEmpty()
        val at = sp.getLong(KEY_SID_AT, 0L)
        if (!forceLogin && cached.isNotEmpty() &&
            System.currentTimeMillis() - at < SID_TTL_MS
        ) {
            return cached
        }
        val base = sp.getString(KEY_BASE_URL, "").orEmpty()
        val user = sp.getString(KEY_USERNAME, "").orEmpty()
        val enc = sp.getString(KEY_PASSWORD_ENC, "").orEmpty()
        if (base.isEmpty() || user.isEmpty() || enc.isEmpty()) {
            throw IllegalStateException("SAF 按需下载未配置凭据（请在 App 里启用一次）")
        }
        val pass = decrypt(enc)
        val otp = sp.getString(KEY_OTP, "").orEmpty()
        val device = sp.getString(KEY_DEVICE_ID, "").orEmpty()
        val params = linkedMapOf(
            "api" to "SYNO.API.Auth",
            "method" to "login",
            "version" to "6",
            "account" to user,
            "passwd" to pass,
            "session" to SESSION_NAME,
            "format" to "sid",
        )
        if (otp.isNotEmpty()) params["otp_code"] = otp
        if (device.isNotEmpty()) params["device_id"] = device
        val body = postForm("${normalize(base)}webapi/entry.cgi", params)
        val json = JSONObject(body)
        if (!json.optBoolean("success", false)) {
            val code = json.optJSONObject("error")?.optInt("code", -1) ?: -1
            throw IllegalStateException("登录失败（DSM 错误码 $code）")
        }
        val sid = json.optJSONObject("data")?.optString("sid").orEmpty()
        if (sid.isEmpty()) throw IllegalStateException("登录成功但没拿到 sid")
        sp.edit()
            .putString(KEY_SID, sid)
            .putLong(KEY_SID_AT, System.currentTimeMillis())
            .apply()
        return sid
    }

    /**
     * 按需下载：`SYNO.SynologyDrive.Files download v2`。
     *
     * 参数与 Dart 侧 `DriveApi.downloadUrl` **逐字一致**
     * （`files=["id:<id>"]` / `force_download=true` / `is_preview=false`）。
     */
    @Throws(Exception::class)
    fun download(ctx: Context, fileId: String, name: String): File {
        val sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!sp.getBoolean(KEY_ON_DEMAND, false)) {
            throw IllegalStateException("SAF 按需下载未开启")
        }
        val dir = File(ctx.cacheDir, ONDEMAND_DIR)
        if (!dir.exists()) dir.mkdirs()
        val dest = File(dir, fileName(fileId, name))
        if (dest.isFile && dest.length() > 0) return dest

        val sid = sid(ctx)
        val base = normalize(sp.getString(KEY_BASE_URL, "").orEmpty())
        val q = listOf(
            "api" to "SYNO.SynologyDrive.Files",
            "method" to "download",
            "version" to "2",
            "files" to "[\"id:$fileId\"]",
            "force_download" to "true",
            "is_preview" to "false",
            "_sid" to sid,
        ).joinToString("&") { "${it.first}=${enc(it.second)}" }
        val url = URL("${base}webapi/entry.cgi?$q")
        val conn = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 15000
            readTimeout = 60000
            instanceFollowRedirects = true
        }
        try {
            val code = conn.responseCode
            if (code !in 200..299) {
                // 会话过期 ⇒ 强制重登一次再试（官方 SDK 也是这个套路）
                if (code == 401 || code == 403) {
                    val fresh = sid(ctx, forceLogin = true)
                    return downloadWithSid(ctx, dest, fresh, fileId, base)
                }
                throw IllegalStateException("下载失败（HTTP $code）")
            }
            // 原子落盘：先 .part 再 rename
            val part = File(dest.absolutePath + ".part")
            conn.inputStream.use { input ->
                FileOutputStream(part).use { out -> input.copyTo(out) }
            }
            if (part.length() == 0L) {
                part.delete()
                throw IllegalStateException("服务端返回空内容")
            }
            // ★ 247 轮真机抓到的 bug：DSM 的业务错误是 **HTTP 200 + JSON 信封**，
            // 上一版会把 `{"success":false,"error":{"code":119}}` 当文件存下来
            // （真机缓存里出现过 38 字节的 `real_*.txt`）。先认错、再落盘。
            rejectDsmEnvelope(part)
            if (!part.renameTo(dest)) {
                part.delete()
                throw IllegalStateException("落盘失败")
            }
            return dest
        } finally {
            conn.disconnect()
        }
    }

    /// 如果 `.part` 其实是 DSM 错误信封 ⇒ 删掉并如实抛错（含错误码）。
    @Throws(Exception::class)
    private fun rejectDsmEnvelope(part: File) {
        if (part.length() > 64L * 1024) return
        val text = part.readText()
        val trimmed = text.trimStart()
        if (!trimmed.startsWith("{")) return
        val json = try {
            JSONObject(trimmed)
        } catch (_: Exception) {
            return // 不是 JSON ⇒ 是文件内容
        }
        if (json.optBoolean("success", true)) return
        val code = json.optJSONObject("error")?.optInt("code", -1) ?: -1
        part.delete()
        throw IllegalStateException("下载被拒绝（DSM 错误码 $code）")
    }

    @Throws(Exception::class)
    private fun downloadWithSid(
        ctx: Context,
        dest: File,
        sid: String,
        fileId: String,
        base: String,
    ): File {
        val q = listOf(
            "api" to "SYNO.SynologyDrive.Files",
            "method" to "download",
            "version" to "2",
            "files" to "[\"id:$fileId\"]",
            "force_download" to "true",
            "is_preview" to "false",
            "_sid" to sid,
        ).joinToString("&") { "${it.first}=${enc(it.second)}" }
        val conn = (URL("${base}webapi/entry.cgi?$q").openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 15000
            readTimeout = 60000
        }
        try {
            val code = conn.responseCode
            if (code !in 200..299) throw IllegalStateException("下载失败（HTTP $code）")
            val part = File(dest.absolutePath + ".part")
            conn.inputStream.use { input ->
                FileOutputStream(part).use { out -> input.copyTo(out) }
            }
            if (part.length() == 0L) {
                part.delete()
                throw IllegalStateException("服务端返回空内容")
            }
            rejectDsmEnvelope(part)
            if (!part.renameTo(dest)) {
                part.delete()
                throw IllegalStateException("落盘失败")
            }
            return dest
        } finally {
            conn.disconnect()
        }
    }

    /** 缓存占用（给 Dart 的 `status()` 用）。 */
    fun onDemandCacheBytes(ctx: Context): Long {
        val dir = File(ctx.cacheDir, ONDEMAND_DIR)
        if (!dir.isDirectory) return 0
        return dir.listFiles()?.sumOf { if (it.isFile) it.length() else 0L } ?: 0L
    }

    fun clearOnDemandCache(ctx: Context): Long {
        val dir = File(ctx.cacheDir, ONDEMAND_DIR)
        val freed = onDemandCacheBytes(ctx)
        dir.deleteRecursively()
        return freed
    }

    /** 与 Dart 侧 `safOnDemandFileName` 一致：`<fileId>_<消毒名>`。 */
    fun fileName(fileId: String, name: String): String {
        val raw = if (name.isEmpty()) fileId else name
        val cleaned = raw
            .replace('/', '_')
            .replace('\\', '_')
            .replace("..", "_")
            .filter { it.code >= 0x20 }
            .trim()
        val safe = when {
            cleaned.isEmpty() -> "file"
            cleaned.length > 120 -> cleaned.substring(0, 120)
            else -> cleaned
        }
        return "${fileId}_$safe"
    }

    // ───────── 小工具 ─────────

    private fun normalize(base: String): String =
        if (base.endsWith("/")) base else "$base/"

    private fun enc(s: String): String = URLEncoder.encode(s, "UTF-8")

    private fun postForm(url: String, params: Map<String, String>): String {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            connectTimeout = 15000
            readTimeout = 30000
            setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        }
        try {
            val body = params.entries.joinToString("&") { "${it.key}=${enc(it.value)}" }
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
            if (code !in 200..299) throw IllegalStateException("HTTP $code: $text")
            return text
        } finally {
            conn.disconnect()
        }
    }

    /** AES/GCM 加密（密钥在 Android Keystore 里，永不导出）。 */
    private fun encrypt(plain: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val iv = cipher.iv
        val body = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(body, Base64.NO_WRAP)
    }

    private fun decrypt(blob: String): String {
        val parts = blob.split(":")
        if (parts.size != 2) throw IllegalStateException("凭据密文损坏")
        val iv = Base64.decode(parts[0], Base64.NO_WRAP)
        val body = Base64.decode(parts[1], Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
        return String(cipher.doFinal(body), Charsets.UTF_8)
    }

    private fun secretKey(): SecretKey {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUserAuthenticationRequired(false)
            .build()
        gen.init(spec)
        return gen.generateKey()
    }

    /** 设备标识（官方也用 `Settings.Secure.ANDROID_ID` 做 device_id）。 */
    fun deviceId(ctx: Context): String =
        android.provider.Settings.Secure.getString(
            ctx.contentResolver,
            android.provider.Settings.Secure.ANDROID_ID,
        ) ?: "${Build.MANUFACTURER}-${Build.MODEL}"
}
