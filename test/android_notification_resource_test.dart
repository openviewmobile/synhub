// r653（`DA256`）：通知栏的**按名字引用的资源**必须活到 release 包里。
//
// 真机事故（`docs/evidence-r653/06_crash_invalid_small_icon.png`）：
// `AudioServiceConfig.androidNotificationIcon` 与 `MediaControl.androidIcon`
// 都是**字符串**（`drawable/xxx`），release 构建的资源压缩看不到引用：
//   * 小图标被删 ⇒ `java.lang.IllegalArgumentException: Invalid notification
//     (no valid small icon)` ⇒ **一按播放就崩**（"SynHub keeps stopping"）；
//   * `audio_service` 的按钮图标被删 ⇒ 通知栏"有 action、没图标"，
//     整行按钮画不出来（r652 之前一直是这个状态）。
// 所以这里钉三件事：① 图标名不许回头用彩色 launcher；② 单色小图标存在；
// ③ `res/raw/keep.xml` 把两类名字都钉住。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  group('DA256 通知栏资源保活', () {
    setUpAll(() {
      expect(
        File('android/app/build.gradle.kts').existsSync(),
        isTrue,
        reason: '这个守卫要在仓库根目录跑（flutter test 的 cwd 即仓库根）',
      );
    });

    test('小图标用**单色** drawable，不许是彩色 launcher', () {
      final src = _read('lib/src/features/media/audio_handler.dart');
      expect(
        src.contains("androidNotificationIcon: 'drawable/ic_stat_audio'"),
        isTrue,
        reason: 'mipmap/ic_launcher 是彩色的：状态栏上会渲染成一个彩色方块，'
            '深色状态栏几乎看不见，也不是 Android 规范要求的剪影图标',
      );
      expect(
        src.contains("androidNotificationIcon: 'mipmap/ic_launcher'"),
        isFalse,
        reason: '彩色 launcher 图标不许回到通知栏',
      );
    });

    test('单色小图标文件存在且是白色剪影 vector', () {
      final f = File('android/app/src/main/res/drawable/ic_stat_audio.xml');
      expect(f.existsSync(), isTrue);
      final xml = f.readAsStringSync();
      expect(xml.contains('<vector'), isTrue);
      expect(xml.contains('pathData'), isTrue);
      expect(
        xml.toUpperCase().contains('#FFFFFFFF') ||
            xml.contains('android:tint'),
        isTrue,
        reason: '小图标要是白色剪影（系统自己染色）',
      );
    });

    test('keep.xml 同时钉住小图标与 audio_service 的按钮图标', () {
      final f = File('android/app/src/main/res/raw/keep.xml');
      expect(
        f.existsSync(),
        isTrue,
        reason: '缺这个文件 ⇒ release 资源压缩会删掉按名字引用的图标（会崩）',
      );
      final xml = f.readAsStringSync();
      expect(xml.contains('tools:keep'), isTrue);
      expect(xml.contains('@drawable/ic_stat_audio'), isTrue);
      expect(
        xml.contains('@drawable/audio_service_*'),
        isTrue,
        reason: 'MediaControl 用的是 audio_service 自带的按钮图标（按名字引用）',
      );
    });

    test('按钮图标名与 audio_service 的既有资源对齐（不是 Material 名字）', () {
      final src = _read('lib/src/features/media/audio_handler.dart');
      for (final name in [
        'audio_service_skip_previous',
        'audio_service_pause',
        'audio_service_play_arrow',
        'audio_service_skip_next',
      ]) {
        expect(
          src.contains("'drawable/$name'"),
          isTrue,
          reason: 'audio_service 的资源名是 audio_service_*；写 ic_* 会解析成 0',
        );
      }
      expect(
        src.contains("'drawable/ic_skip_previous'") ||
            src.contains("'drawable/ic_play_arrow'"),
        isFalse,
        reason: '这些 Material 名字在本 App 里不存在（解析成 0 ⇒ 按钮没图标）',
      );
    });
  });
}
