// 图生图**本地预检**测试：重点在 **EXIF（含 GPS）剥离的字节级证据**。
//
// 这一批最重要的"隐私断言"就在这里：照片在离开设备之前，必须已经把
// EXIF（含 GPS IFD）从字节里去掉。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:synhub/src/core/media/image_edit_prepare.dart';
import 'package:synhub/src/core/media/image_prepare.dart'
    show kStandardImageMaxEdge;
import 'package:synhub/src/data/ai/image_edit_client.dart';

/// 造一张**带 GPS IFD 与相机信息**的 JPEG（测试夹具）
Uint8List _gpsJpeg({int w = 200, int h = 120}) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(180, 40, 60));
  image.exif.imageIfd['Make'] = 'TestCam';
  image.exif.imageIfd['Model'] = 'GPS-1';
  // 真正的 GPS 子 IFD（标签 0x1=GPSLatitudeRef / 0x3=GPSLongitudeRef）
  image.exif.gpsIfd.data[0x1] = img.IfdValueAscii('N');
  image.exif.gpsIfd.data[0x3] = img.IfdValueAscii('E');
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

Uint8List _plainJpeg({int w = 200, int h = 120}) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(10, 120, 220));
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

void main() {
  test('夹具本身确实带 EXIF + GPS IFD（否则后面的"已剥离"没有意义）', () {
    final fixture = _gpsJpeg();
    final at = findExifSegment(fixture);
    expect(at, greaterThanOrEqualTo(0), reason: '夹具必须含 Exif\\0\\0 段');
    expect(gpsIfdTagCount(fixture), greaterThan(0), reason: '夹具必须含 GPS IFD');
    // 打印偏移当证据（红/绿报告里引用）
    // ignore: avoid_print
    print(
      '[evidence] fixture bytes=${fixture.length} exifAt=$at gpsTags=${gpsIfdTagCount(fixture)}',
    );
  });

  test('prepareImageForEdit 输出：字节里不含 EXIF 段、不含 GPS IFD', () {
    final fixture = _gpsJpeg();
    final prepared = prepareImageForEdit(bytes: fixture, fileName: 'IMG_1.jpg');

    expect(findExifSegment(prepared.bytes), -1, reason: '输出不得含 Exif 段');
    expect(hasExifSegment(prepared.bytes), isFalse);
    expect(gpsIfdTagCount(prepared.bytes), 0, reason: '输出不得含 GPS IFD');
    // 输出仍是合法 JPEG，且能被解码
    final decoded = img.decodeImage(prepared.bytes);
    expect(decoded, isNotNull);
    expect(prepared.mimeType, 'image/jpeg');
    expect(prepared.fileName, endsWith('.jpg'));

    // ignore: avoid_print
    print(
      '[evidence] output bytes=${prepared.bytes.length} '
      'exifAt=${findExifSegment(prepared.bytes)} gpsTags=${gpsIfdTagCount(prepared.bytes)}',
    );
  });

  test('反例（记录事实）：直接用 decodeImage + encodeJpg **不剥离** EXIF', () {
    // 这正是 `image_prepare.dart` 的既有行为：`encodeJpg` 会把 `image.exif` 写回去，
    // 所以图生图不能只依赖它，必须显式清空 exif（本文件被测函数做的事）。
    final fixture = _gpsJpeg();
    final decoded = img.decodeImage(fixture)!;
    final naive = Uint8List.fromList(img.encodeJpg(decoded, quality: 90));
    expect(
      hasExifSegment(naive),
      isTrue,
      reason: '未清空 exif 时 EXIF 会原样写回（证明"复用 prepareImageUpload 不够"）',
    );
    expect(gpsIfdTagCount(naive), greaterThan(0));
  });

  test('大图缩边：长边 2000 → 1280', () {
    final big = _plainJpeg(w: 2000, h: 1000);
    final prepared = prepareImageForEdit(bytes: big, fileName: 'big.jpg');
    final decoded = img.decodeImage(prepared.bytes)!;
    final longEdge = decoded.width > decoded.height
        ? decoded.width
        : decoded.height;
    expect(longEdge, kStandardImageMaxEdge);
    expect(prepared.resized, isTrue);
    expect(prepared.width, kStandardImageMaxEdge);
  });

  test('不是图片 / 空字节 → inputNotImage（不静默、不发请求）', () {
    expect(
      () => prepareImageForEdit(
        bytes: Uint8List.fromList([1, 2, 3, 4]),
        fileName: 'x.jpg',
      ),
      throwsA(
        isA<ImageEditException>().having(
          (e) => e.kind,
          'kind',
          ImageEditErrorKind.inputNotImage,
        ),
      ),
    );
    expect(
      () => prepareImageForEdit(bytes: Uint8List(0), fileName: 'x.jpg'),
      throwsA(
        isA<ImageEditException>().having(
          (e) => e.kind,
          'kind',
          ImageEditErrorKind.inputNotImage,
        ),
      ),
    );
  });

  test('超体积 → 本地先拦 imageTooLarge（不等服务端 413）', () {
    final bytes = _plainJpeg();
    expect(
      () => prepareImageForEdit(
        bytes: bytes,
        fileName: 'x.jpg',
        maxBytes: 100, // 单测注入极小上限，避免造 50MB 图
      ),
      throwsA(
        isA<ImageEditException>()
            .having((e) => e.kind, 'kind', ImageEditErrorKind.imageTooLarge)
            .having((e) => e.message, 'message', contains('照片过大')),
      ),
    );
  });

  test('动图被展平 → flattenedAnimation=true（如实告知，不默默丢动画）', () {
    final gif = img.Image(width: 32, height: 32, numChannels: 4);
    img.fill(gif, color: img.ColorRgba8(1, 2, 3, 255));
    gif.addFrame(img.Image(width: 32, height: 32, numChannels: 4)..clear());
    final bytes = Uint8List.fromList(img.encodeGif(gif));
    final prepared = prepareImageForEdit(bytes: bytes, fileName: 'anim.gif');
    expect(prepared.flattenedAnimation, isTrue);
    expect(hasExifSegment(prepared.bytes), isFalse);
  });
}
