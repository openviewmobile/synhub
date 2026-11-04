import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── 发布签名（W0-4 / r352）──────────────────────────────────────────────
// release 包体必须用**发布密钥**签，否则不是一个可发布的产物（旧脚本一直
// 借 `signingConfigs.getByName("debug")`，那是占位 TODO）。
//
// ★ 凭据**不进仓库**：口令只从环境变量取（首选）或 `android/key.properties`
//   （本机私有文件，键名见下）取。两者都没有时**明确回落 debug 并打警告**，
//   而不是静默签出一个看起来像发布包的东西。
//
//   环境变量：SYNHUB_KEYSTORE_FILE / SYNHUB_KEYSTORE_PASSWORD /
//            SYNHUB_KEY_ALIAS / SYNHUB_KEY_PASSWORD（省略时 = store 口令）
//   properties 键：storeFile / storePassword / keyAlias / keyPassword
val _keystoreProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

fun _secret(envName: String, propName: String): String? =
    System.getenv(envName)?.takeIf { it.isNotBlank() }
        ?: _keystoreProps.getProperty(propName)?.takeIf { it.isNotBlank() }

val _ksFile = _secret("SYNHUB_KEYSTORE_FILE", "storeFile")
val _ksStorePassword = _secret("SYNHUB_KEYSTORE_PASSWORD", "storePassword")
val _ksAlias = _secret("SYNHUB_KEY_ALIAS", "keyAlias")
val _ksKeyPassword = _secret("SYNHUB_KEY_PASSWORD", "keyPassword") ?: _ksStorePassword
val _hasReleaseKeystore = _ksFile != null && _ksStorePassword != null &&
    _ksAlias != null && _ksKeyPassword != null && file(_ksFile).exists()

android {
    namespace = "com.openviewai.synhub"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.openviewai.synhub"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 只出 arm64-v8a（原 App 也只支持 arm64 设备；我们跑在 LGE AN10 上）。
        // ⚠️ 注意 `abiFilters` **拦不住 Flutter 引擎库**：`flutter build apk`
        // 默认是 fat 包，Gradle 插件会把 `--target-platform` 里所有 ABI 的
        // `libflutter.so` / `libapp.so` / 插件 `.so` 直接作为 jniLibs 塞进来，
        // abiFilters 只作用于 NDK 自己编出来的东西 —— 实测 fat 包里 x86_64、
        // armeabi-v7a 一个不少（75.4MB，光原生库就 73.5MB）。
        // 真正兜底的是下面 `packaging.jniLibs.excludes`：不管谁带进来的非
        // arm64 `.so` 一律不进包，所以**默认**的 `flutter build apk --release`
        // 就是 arm64-only（实测 27.3MB）。
        // 想更快/更省中间产物可以再显式加 `--target-platform=android-arm64`
        // （这样压根不构建其它 ABI 的 libapp.so）。
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    packaging {
        jniLibs {
            // 除了 arm64-v8a，其它 ABI 的 .so 全部剔除（含引擎/插件带进来的）
            excludes += setOf(
                "lib/armeabi-v7a/**",
                "lib/x86/**",
                "lib/x86_64/**",
                "lib/mips/**",
                "lib/mips64/**",
                "lib/riscv64/**",
                // 端侧 AI（flutter_gemma_litertlm 的 native asset）会带一堆
                // 用不到的加速后端，实测把 APK 从 31.9MB 顶到 144MB：
                //   * QNN HTP 的 **Skel** 库（4 个 SoC 档，共 ~46MB）：跑在高通
                //     Hexagon DSP 上，只有选 NPU 后端才用；我们的模型档位用
                //     CPU/GPU，Stub（CPU 侧桥）保留即可；
                //   * WebGPU 加速器/采样器（~9MB）：那是 Linux/Windows 的
                //     后端，Android 走 OpenCL；
                // 真机上装完模型跑通一次才算数（见 docs/on-device-ai-integration.md）。
                "lib/**/libQnnHtpV73Skel.so",
                "lib/**/libQnnHtpV75Skel.so",
                "lib/**/libQnnHtpV79Skel.so",
                "lib/**/libQnnHtpV81Skel.so",
                "lib/**/libLiteRtWebGpuAccelerator.so",
                "lib/**/libLiteRtTopKWebGpuSampler.so",
            )
        }
    }

    signingConfigs {
        if (_hasReleaseKeystore) {
            create("release") {
                storeFile = file(_ksFile!!)
                storePassword = _ksStorePassword
                keyAlias = _ksAlias
                keyPassword = _ksKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (_hasReleaseKeystore) {
                logger.lifecycle(
                    "[signing] release 用发布密钥：${_ksFile}（alias=${_ksAlias}）"
                )
                signingConfigs.getByName("release")
            } else {
                logger.lifecycle(
                    "[signing] !! 缺少 SYNHUB_KEYSTORE_*（或 android/key.properties）" +
                        " ⇒ 回落 debug 签名：**该产物不可发布**，只可用于真机功能验收"
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // 自研播放器桥 `MediaPlayerBridge.kt` 直接使用 Media3/ExoPlayer。
    //
    // 为什么必须在这里显式声明：`video_player_android` 2.8.7 内部用的也是这套库，
    // 但它是以 `implementation` 依赖的 —— **不会**暴露到 app 模块的编译类路径上，
    // 只写 Kotlin 的话会 `unresolved reference: media3`。
    //
    // 版本说明：下面这个 `1.4.1` 是**最低/声明**版本，**不是**实际解析版本 ——
    // 实际版本由 Gradle 依赖解析抬升（`video_player_android` 等传递依赖可能更高）。
    // 当前构建实际解析为 **1.9.2**，证据：
    // `build/app/outputs/sdk-dependencies/release/sdkDependencies.txt` 里
    // `artifactId: "media3-exoplayer"` → `version: "1.9.2"`；设备 logcat 也能看到
    // `[AndroidXMedia3/1.9.2]`。查法：跑一次 release 构建后看上面那个文件。
    // 这里**不改依赖坐标**（改坐标会带来行为变化），只保证注释与事实一致。
    // `media3-common` / `media3-datasource` 由 `media3-exoplayer` 传递进来，
    // 不用重复声明。
    implementation("androidx.media3:media3-exoplayer:1.4.1")

    // C3 Chromecast：官方 DSaudio 就是这套 SDK（dex 里 com/google/android/gms/cast/*
    // 293 处），接收器用的是**默认媒体接收器** `CC1AD845`
    // （官方 dex 字符串里逐个搜到的就是它，与
    //  `CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID` 一致）。
    implementation("com.google.android.gms:play-services-cast-framework:21.5.0")

    // 相册「手机自动备份」的后台层 `PhotoBackupWorker.kt` / `PhotoBackupPlugin.kt`
    // 直接用 WorkManager（CoroutineWorker / Constraints / PeriodicWorkRequest）。
    //
    // 为什么必须显式声明：本项目没有引入任何提供 WorkManager 的 Flutter 插件，
    // 不声明则 app 模块编译类路径上根本没有 `androidx.work.*`（unresolved reference）。
    // 版本 `2.11.0` 与本地 Gradle 缓存里已有的
    // `~/.gradle/caches/modules-2/files-2.1/androidx.work/work-runtime-ktx/2.11.0`
    // 对齐；`work-runtime-ktx` 会传递把 `work-runtime`（含 CoroutineWorker 与
    // kotlinx-coroutines）带进来，所以只声明这一个坐标就够。
    implementation("androidx.work:work-runtime-ktx:2.11.0")
}

flutter {
    source = "../.."
}
