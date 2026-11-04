// 用 Android Keystore 里的 AES-256-GCM 密钥保护"必须静态保存的机密"。
//
// 对齐原版 `util/LegacyKeystoreHelper.java`（RSA-2048 放在 AndroidKeyStore、
// alias `SYNOAPP`、分块 `RSA/ECB/PKCS1Padding`）：原版把整对
// `Base64ChatKeyPair`（**含 privateKeyEnc**）先 Gson 序列化、再经 Keystore
// 加密，最后按 `CipherData` 的形式（`base64(json{long:base64(ct),short:base64(iv)})`）
// 存进 SharedPreferences（`PreferencesHelper.setBase64KeyPair`）。
//
// 我们的取舍：换 **AES/GCM**（更现代、带认证、不用自己分块），alias
// `synhub_secrets`，输出 `v1:<base64(iv)>:<base64(ct+tag)>`，
// 业务层只当它是"能封能开的不透明串"。原版的 RSA 格式不需要兼容 ——
// 那是它自己 SharedPreferences 里的东西，我们不迁移。
package com.openviewai.synhub

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

object KeystoreBridge {
    const val CHANNEL = "synhub/keystore"
    private const val TAG = "SynologyChatKeystore"
    private const val ALIAS = "synhub_secrets"
    private const val PROVIDER = "AndroidKeyStore"
    private const val PREFIX = "v1"
    private const val GCM_TAG_BITS = 128

    fun attach(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "seal" -> {
                        val plain = call.argument<String>("plain").orEmpty()
                        try {
                            result.success(seal(plain))
                        } catch (e: Exception) {
                            Log.w(TAG, "seal 失败：${e.message}")
                            result.error("seal_failed", e.message, null)
                        }
                    }
                    "open" -> {
                        val encoded = call.argument<String>("encoded").orEmpty()
                        try {
                            result.success(open(encoded))
                        } catch (e: Exception) {
                            Log.w(TAG, "open 失败：${e.message}")
                            result.error("open_failed", e.message, null)
                        }
                    }
                    "isAvailable" -> result.success(key() != null)
                    else -> result.notImplemented()
                }
            }
    }

    /** 封：AES-GCM，随机 IV 由系统生成，输出 `v1:<iv>:<ct+tag>` */
    private fun seal(plain: String): String? {
        if (plain.isEmpty()) return null
        val key = key() ?: return null
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val ct = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        val iv = cipher.iv
        return "$PREFIX:${b64(iv)}:${b64(ct)}"
    }

    /** 开：失败（Keystore 密钥没了 / 串被改过）返回 null，让上层走"重新取服务端身份" */
    private fun open(encoded: String): String? {
        if (encoded.isEmpty()) return null
        val parts = encoded.split(':')
        if (parts.size != 3 || parts[0] != PREFIX) {
            Log.w(TAG, "不认识的密文格式")
            return null
        }
        val key = key() ?: return null
        val iv = Base64.decode(parts[1], Base64.NO_WRAP)
        val ct = Base64.decode(parts[2], Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
        return String(cipher.doFinal(ct), Charsets.UTF_8)
    }

    /** 取（必要时生成）Keystore 里的那把 AES 密钥 */
    private fun key(): SecretKey? = try {
        val store = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (store.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey
            ?: generate()
    } catch (e: Exception) {
        Log.w(TAG, "Keystore 不可用：${e.message}")
        null
    }

    private fun generate(): SecretKey {
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        gen.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        return gen.generateKey()
    }

    private fun b64(bytes: ByteArray): String =
        Base64.encodeToString(bytes, Base64.NO_WRAP)
}
