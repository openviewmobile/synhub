// 对应缺陷 **DA175**（"动态取色"是假开关：无 M3 的机器上恒 null ⇒ 界面永远品牌蓝）。
// 第 231 轮：**壁纸取色**的解析与回退判据。
//
// 用户裁定：「Material You 保留默认开，而且需要想办法让它真正取到壁纸色」。
// 这条链路的三个关键行为都在这里钉住：
//   ① 原生回包的三种来源能正确解析（`wallpaperColors` / `bitmap` / `none`）；
//   ② **灰度/劣质壁纸不许当 seed**（取出来比品牌蓝更难看 ⇒ 回退）；
//   ③ 通道不通（老平台/桌面/测试环境）**不许抛**，必须回 `none` 并带上原因。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/wallpaper_seed.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WallpaperSeed.fromMap', () {
    test('系统壁纸主色：来源与色值都解析出来', () {
      final s = WallpaperSeed.fromMap({
        'source': 'wallpaperColors',
        'seed': 0x3F5AA6,
        'saturation': 0.62,
        'sdkInt': 34,
      });
      expect(s.source, WallpaperColorSource.wallpaperColors);
      expect(s.seed, 0x3F5AA6);
      expect(s.color, const Color(0xFF3F5AA6));
      expect(s.usable, isTrue);
      expect(s.detail, contains('sdk=34'));
    });

    test('自读位图路径：来源是 bitmap', () {
      final s = WallpaperSeed.fromMap({
        'source': 'bitmap',
        'seed': 0x112233,
        'saturation': 0.5,
      });
      expect(s.source, WallpaperColorSource.bitmap);
      expect(s.usable, isTrue);
    });

    test('拿不到：source=none ⇒ 不可用，且带上原生给的原因', () {
      final s = WallpaperSeed.fromMap({
        'source': 'none',
        'seed': 0,
        'saturation': 0.0,
        'bitmapError': 'noDrawable',
      });
      expect(s.source, WallpaperColorSource.none);
      expect(s.color, isNull);
      expect(s.usable, isFalse);
      expect(s.detail, contains('bitmap=noDrawable'));
    });

    test('灰度壁纸（饱和度过低）⇒ 判为不可用（宁可品牌蓝）', () {
      final s = WallpaperSeed.fromMap({
        'source': 'wallpaperColors',
        'seed': 0x777777,
        'saturation': 0.03,
      });
      expect(s.color, isNotNull, reason: '颜色本身还是有值的');
      expect(s.usable, isFalse, reason: '但饱和度太低，不许拿来当 seed');
    });

    test('类型不齐也要兜住（字符串数字 / 缺字段 / 完全非 Map）', () {
      final a = WallpaperSeed.fromMap({
        'source': 'bitmap',
        'seed': '4660',
        'saturation': '0.4',
      });
      expect(a.seed, 4660);
      expect(a.saturation, closeTo(0.4, 1e-9));

      final b = WallpaperSeed.fromMap({'source': 'weird'});
      expect(b.source, WallpaperColorSource.none);
      expect(b.seed, isNull);

      final c = WallpaperSeed.fromMap('nope');
      expect(c.source, WallpaperColorSource.none);
      expect(c.detail, 'noMap');
    });
  });

  group('readWallpaperSeed（通道）', () {
    const channel = MethodChannel(kWallpaperChannel);
    TestDefaultBinaryMessenger messenger() =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger().setMockMethodCallHandler(channel, null));

    test('通道回包 ⇒ 解析成可用 seed', () async {
      messenger().setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'seed');
        return {
          'source': 'wallpaperColors',
          'seed': 0x2277CC,
          'saturation': 0.71,
        };
      });
      final s = await readWallpaperSeed(channel: channel);
      expect(s.source, WallpaperColorSource.wallpaperColors);
      expect(s.usable, isTrue);
      expect(s.seed, 0x2277CC);
    });

    test('★ 通道抛异常 ⇒ 回 none，绝不冒泡', () async {
      messenger().setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'boom');
      });
      final s = await readWallpaperSeed(channel: channel);
      expect(s.source, WallpaperColorSource.none);
      expect(s.usable, isFalse);
      expect(s.detail, contains('channel='));
    });

    test('原生回 null ⇒ none', () async {
      messenger().setMockMethodCallHandler(channel, (call) async => null);
      final s = await readWallpaperSeed(channel: channel);
      expect(s.source, WallpaperColorSource.none);
    });
  });
}
