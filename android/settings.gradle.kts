pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    // ★ r668：2.4.0 让 `background_downloader 9.6.4` 的 `Collections.synchronizedMap(HashMap<…>())`
    //   报 "Cannot infer type for type parameter K/V"（Kotlin 2.4 收紧推断）⇒ 钉 2.2.21（Flutter 3.47 的最低要求是 2.2.20）。
    id("org.jetbrains.kotlin.android") version "2.2.21" apply false
}

include(":app")
