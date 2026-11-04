package com.openviewai.synhub

import android.content.Intent
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// ⚠️ 必须仍是 **FragmentActivity** 家族：local_auth 的 BiometricPrompt 依赖
// FragmentActivity（Phase 9 生物识别解锁）。
//
// 这里继承 `AudioServiceFragmentActivity`（audio_service 官方包提供），它本身
// 就是 `FlutterFragmentActivity` 的子类 → 同时满足两边的约束：
//   * 生物识别（FragmentActivity）
//   * 音频后台播放的 MediaSession/媒体按键接线（AudioService）
// 已核对官方包源码：`class AudioServiceFragmentActivity extends FlutterFragmentActivity`
// （audio_service-0.18.19/android/.../AudioServiceFragmentActivity.java:12）。
// 注意：**不是** `AudioServiceActivity` —— 那个继承的是 `FlutterActivity`，
// 会丢掉 FragmentActivity，从而打坏生物识别。
// 其余生命周期回调与 9 个桥接（configureFlutterEngine）保持不变。
class MainActivity : AudioServiceFragmentActivity() {
    companion object {
        /** 当前前台 Activity（申请通知权限、点通知跳频道要用） */
        @Volatile
        var current: MainActivity? = null
            private set
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        current = this
        // 「分享到 Chat」：冷启动时带来的 ACTION_SEND / ACTION_SEND_MULTIPLE
        // （exported intent-filter 见 AndroidManifest.xml，Dart 侧消费见
        //  ShareIntentBridge 的头注释）
        ShareIntentBridge.handleIntent(intent)
        // 主屏快捷方式（文件 M72）：冷启动时带来的目标目录
        ShortcutBridge.handleIntent(intent)
        // 聊天深链（审计行 262）：冷启动时点 `synochat://…` 链接
        DeepLinkBridge.handleIntent(intent)
        // 主屏小组件（P66 相册 / N1 笔记）：冷启动时点小组件带来的落点
        SynologyWidgetBridge.handleIntent(intent)
        // r653（DA257）：点媒体通知（audio_service 的 contentIntent）→ 回播放页
        MediaNotificationTapBridge.handleIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 通知/前台服务的 MethodChannel（Phase 8）
        BackgroundBridge.attach(applicationContext, flutterEngine)
        // 带 MIME 的 ACTION_VIEW（音频/视频串流交给外部播放器，Phase 5）
        MediaOpenBridge.attach(applicationContext, flutterEngine)
        // Android Keystore 包一层（E2EE 身份的静态保护，Phase 7）
        KeystoreBridge.attach(flutterEngine)
        // 当前网络类型（"收到通知时预加载消息"默认仅 Wi-Fi，Phase 9）
        NetworkBridge.attach(applicationContext, flutterEngine)
        // 按 UID 的流量计数（只读；Dart 侧在**已知活动会话**前后差分，
        // 归属原生组件绕过 Dio 的那部分流量，第 276 轮）
        TrafficStatsBridge.attach(flutterEngine)
        // ★ 壁纸取色（第 231 轮）：Material You 在无 M3 的机器上拿不到，
        // 这里补一条「读壁纸主色」的只读通道，让"跟随壁纸"不再是假开关。
        WallpaperBridge.attach(applicationContext, flutterEngine)
        // 设备型号（官方 DSnote `commit_msg.device` = `Build.MODEL`，第 112 轮）
        DeviceModelBridge.attach(applicationContext, flutterEngine)
        // ★ 第 278 轮：厂商（OEM）兼容事实 —— 厂商 id / ROM 版本 / **验真过的**
        // 自启动系统页组件（只读；Dart 侧据此显示逐家的保活指引，见
        // `lib/src/features/settings/oem_keepalive_page.dart`）
        OemCompatBridge.attach(applicationContext, flutterEngine)
        // 笔记后台同步（官方 SyncService 的对应物；第 114 轮 M3）
        NoteSyncPlugin.attach(applicationContext, flutterEngine)
        // 系统定位（日历的天气/节假日要"我现在在哪儿"）
        LocationBridge.attach(this, flutterEngine)
        // 本机相册读取（相册"手机自动备份"的源）
        MediaLibraryBridge.attach(this, flutterEngine)
        // 自研视频播放器（Media3/ExoPlayer：轨道/字幕/音量/画面比例/播放列表）
        MediaPlayerBridge.attach(this, flutterEngine)
        // r654（DA259）：视频画中画（进/出 + 手势自动进入；状态回传 Dart）
        VideoPipBridge.attach(this, flutterEngine)
        // B10 均衡器：android.media.audiofx.Equalizer（段/预设运行时枚举，不硬编码）
        EqualizerBridge.attach(flutterEngine)
        // 播放律动的**真频谱**（第 274 轮）：android.media.audiofx.Visualizer。
        // 通道 `synhub/audio_visualizer`。**只在 RECORD_AUDIO 已授予时**
        // 才建（本 App 因聊天语音消息本来就声明了它），否则回 ok=false，
        // Dart 侧回落既有推导动效 —— 这条路径**绝不弹权限框**。
        AudioVisualizerBridge.attach(this, flutterEngine)
        // C3 Chromecast：GMS Cast SDK（与官方同一套；默认媒体接收器）
        CastBridge.attach(this, flutterEngine)
        // F12 下载完成通知（本地通知，不依赖 FCM）
        DownloadNotifications.attach(flutterEngine.dartExecutor.binaryMessenger, this)
        // 「分享到 Chat」的入站意图 → Dart
        // （传 Activity 而非 applicationContext：attach 里要顺便看一眼启动 Intent，
        //  这样冷启动分享不依赖 onCreate/attach 的先后顺序）
        ShareIntentBridge.attach(this, flutterEngine)
        // 待办提醒 / 每日逾期汇总的系统级闹钟（Android 平台批 A）
        // AlarmManager 精确闹钟 + 通知渠道 dsnote + 开机重排
        NoteReminderPlugin.attach(applicationContext, flutterEngine)

        // ★ D84（214 轮）：专注备份和同步的**调暗屏幕 + 保持常亮**
        // （官方 SleepBackupActivity.handleScreenDimming）。要 Activity 才能改
        // 窗口亮度，所以传 this。
        SleepBackupBridge.attach(this, flutterEngine)
        // ★ D84（222 轮）：休眠备份的 **60min 常驻周期任务**（WorkManager
        // PeriodicWorkRequest，flex 10min）。Dart 侧调度时算好判定与文案。
        SleepBackupWorker.attach(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        // ★ D65（228 轮）：Drive 同步任务的**原生常驻文件监听**
        // （Service + FileObserver；App 被杀后 START_STICKY 重启继续盯）
        DriveFileWatchBridge.attach(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        // ★ D66（246 轮）：SAF 按需下载的凭据存储/预取（provider 冷启动自登录用）
        DriveSafBridge.attach(applicationContext, flutterEngine)
        // r653（DA257）：点媒体通知的落点（通道 `synhub/media_notification_tap`）
        MediaNotificationTapBridge.attach(flutterEngine)
        // ★ J9（235 轮）：把笔记正文分享出去（ACTION_SEND + chooser）
        ShareTextBridge.attach(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        // 相册「手机自动备份」：WorkManager 后台任务 + headless 引擎（后台跑 Dart 备份）
        PhotoBackupPlugin.attach(applicationContext, flutterEngine)
        // 主屏快捷方式（文件模块 M72）：请求固定目录快捷方式 + 取回待跳转目录
        ShortcutBridge.attach(this, flutterEngine)
        // 导出到系统「下载」目录（文件模块 M68，审计行 220）：
        // MediaStore.Downloads 插入（API 29+ 免权限），通道 `synhub/mediastore`
        MediaStoreBridge.attach(applicationContext, flutterEngine)
        // 视频首帧抽帧（第 261 轮）：`android.media.MediaMetadataRetriever`
        // 薄桥，通道 `synhub/video_frame`。**不申请任何新权限**
        // （抽帧不需要权限）；网络由 Dart 侧负责，这里只吃本地临时文件路径。
        // 服务端实测没有视频缩略图（docs/thumbnail-apis.md）⇒ 这是自研兜底。
        VideoFrameBridge.attach(flutterEngine, applicationContext)
        // 聊天深链（审计行 262）：`synhub/deep_link` 通道
        DeepLinkBridge.attach(flutterEngine)
        // 主屏小组件（P66 相册 / N1 笔记）：快照落盘 + 点击落点，
        // 通道 `synhub/widget`（传 this：attach 里顺便补看一次启动 Intent）
        SynologyWidgetBridge.attach(this, flutterEngine)
        // ★ 第 294 轮：折叠姿态（铰链角）。本机 `displayFeatures` **恒空**
        // （真机取证见 `FoldPostureBridge` 类注释），所以折痕避让需要传感器
        // 这条真值来源。**不申请任何权限**（普通传感器）；注册/注销跟随
        // onResume/onPause/onDestroy，**不在这里常驻注册**。
        FoldPostureBridge.attach(applicationContext, flutterEngine)
        // ★★ DA62（第 409 轮）：内置链接浏览器页的系统返回键
        // （WebView 加载过页面后按键到不了 Flutter ⇒ 必须在视图树之前吃）。
        // 只在 Dart 侧"本页在前台"时生效，见 BrowserBackBridge 类注释。
        BrowserBackBridge.attach(flutterEngine)
    }

    /**
     * r654（`DA259`）：画中画进/出。
     *
     * 系统手势（Home / 上滑）进入小窗时 Dart 从来没调过我们的 `enter()`，
     * 所以**状态必须由系统回调回传**；漏了这一条，小窗里会继续画整套控制条。
     */
    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: android.content.res.Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        VideoPipBridge.onModeChanged(isInPictureInPictureMode)
    }

    /** 折叠姿态传感器只在**前台且有 Dart 监听者**时才注册（见桥的类注释）。 */
    override fun onResume() {
        super.onResume()
        FoldPostureBridge.onResume()
    }

    /**
     * ★★ DA62（第 409 轮）：**在视图树之前**处理返回键。
     *
     * 真机实测（`docs/android-ui-audit-r409.md` §S2，三组同刻 dump）：内置链接
     * 浏览器页只要 **WebView 加载过任何一页**，`keyevent 4` 就再也到不了 Flutter
     * （既不退页、也不回历史；焦点在 Flutter 输入框还是网页内容**结果一样**）
     * ⇒ "在 Dart 侧加 `PopScope`"这类修法无效，只能在这一层吃。
     *
     * 桥只有 Dart 侧明确"本页在前台"时才启用；否则 `handleKey` 直接返回 false，
     * 走 `super`，**其它页面/其它时刻的行为与改前一字不差**。
     */
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
        if (BrowserBackBridge.handleKey(event)) return true
        return super.dispatchKeyEvent(event)
    }

    override fun onPause() {
        FoldPostureBridge.onPause()
        super.onPause()
    }

    /**
     * ⚠️ `LocationBridge` / `MediaLibraryBridge` 申请权限时要拿结果：
     * `ActivityCompat.requestPermissions` 的回调只到 Activity，所以这里转发一下
     * （不是我们的 requestCode 就交给 super）。
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (LocationBridge.onPermissionResult(requestCode, grantResults)) return
        if (MediaLibraryBridge.onPermissionResult(requestCode, grantResults)) return
        // 待办提醒的 POST_NOTIFICATIONS（13+）
        if (NoteReminderPlugin.onPermissionResult(requestCode, grantResults)) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    /**
     * ⚠️ 「释放手机空间」（P51）的系统删除确认框要拿结果：`MediaStore`
     * `createDeleteRequest` 的 PendingIntent 回调只到 Activity，所以这里转发一下
     * （不是我们的 requestCode 就交给 super）。
     */
    @Deprecated("Deprecated in Java")
    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (MediaLibraryBridge.onActivityResult(requestCode, resultCode)) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        if (current === this) current = null
        BackgroundBridge.detach()
        MediaLibraryBridge.detach()
        MediaPlayerBridge.detach()
        EqualizerBridge.detach()
        AudioVisualizerBridge.detach()
        CastBridge.detach()
        FoldPostureBridge.detach()
        // DA62：Activity 没了就别再吃返回键（不留"吃了却没人处理"的状态）
        BrowserBackBridge.disarm()
        super.onDestroy()
    }

    /** 点通知进来时把 channel_id 交给 Dart（`getIntent` 方式即可） */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // App 已经在前台时从别的 App「分享到 Chat」
        ShareIntentBridge.handleIntent(intent)
        // App 已经在前台时点主屏快捷方式（singleTop → onNewIntent）
        ShortcutBridge.handleIntent(intent)
        // App 已经在前台时点聊天深链（singleTop → onNewIntent）
        DeepLinkBridge.handleIntent(intent)
        // App 已经在前台时又点了一次小组件（singleTop → onNewIntent）
        // → 通过 `onWidgetAction` 事件通知 Dart 取落点
        SynologyWidgetBridge.handleIntent(intent)
        // r653（DA257）：App 已经在前台时点媒体通知 → 直接回播放页
        MediaNotificationTapBridge.handleIntent(intent)
    }
}
