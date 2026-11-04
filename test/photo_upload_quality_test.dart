// ⑦相册 **P43 上传质量档**用例：压缩逻辑（真字节）+ 队列接线。
//
// 说明：压缩是**纯客户端**行为（服务端 `SYNO.Foto.Upload.so` 无质量/尺寸参数），
// 所以这里用 `package:image` 现造真实 JPEG 来验，不 mock 像素。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:synhub/src/data/media/device_media_library.dart';
import 'package:synhub/src/features/photos/photo_backup_queue.dart';
import 'package:synhub/src/features/photos/photo_upload_quality.dart';

Future<void> _settle([int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

late Directory _tmp;

Uint8List _jpeg(int w, int h) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(x, y, x % 256, y % 256, (x + y) % 256);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 95));
}

File _write(String name, List<int> bytes) {
  final f = File('${_tmp.path}/$name')..writeAsBytesSync(bytes);
  return f;
}

void main() {
  setUpAll(() {
    _tmp = Directory.systemTemp.createTempSync('photo_quality_test');
  });
  tearDownAll(() {
    if (_tmp.existsSync()) _tmp.deleteSync(recursive: true);
  });

  group('PhotoUploadQuality', () {
    test('fromId：认得的返回对应档，认不出/空 → original（最安全）', () {
      expect(PhotoUploadQuality.fromId('high'), PhotoUploadQuality.high);
      expect(PhotoUploadQuality.fromId('low'), PhotoUploadQuality.low);
      expect(PhotoUploadQuality.fromId('nope'), PhotoUploadQuality.original);
      expect(PhotoUploadQuality.fromId(null), PhotoUploadQuality.original);
    });

    test('快照落盘往返：upload_quality 记住；老 JSON（无此键）→ original', () {
      const snap = PhotoBackupSnapshot(uploadQuality: PhotoUploadQuality.medium);
      expect(
        PhotoBackupSnapshot.decode(snap.encode()).uploadQuality,
        PhotoUploadQuality.medium,
      );
      expect(
        PhotoBackupSnapshot.decode('{"include_videos":true}').uploadQuality,
        PhotoUploadQuality.original,
      );
      // 脏数据不炸
      expect(PhotoBackupSnapshot.decode('{oops').uploadQuality,
          PhotoUploadQuality.original);
    });
  });

  group('ImageUploadCompressor（真字节）', () {
    final c = ImageUploadCompressor();

    test('原图档：**返回原路径**，文件不动', () async {
      final f = _write('a.jpg', _jpeg(3000, 2000));
      final before = f.lengthSync();
      final out = await c.compress(
        localPath: f.path,
        quality: PhotoUploadQuality.original,
      );
      expect(out, f.path);
      expect(f.lengthSync(), before);
    });

    test('高档：长边压到 2048 且体积变小，产出是真正可解码的 JPEG', () async {
      final f = _write('b.jpg', _jpeg(3000, 2000));
      final out = await c.compress(
        localPath: f.path,
        quality: PhotoUploadQuality.high,
      );
      expect(out, isNot(f.path));
      final decoded = img.decodeImage(File(out).readAsBytesSync())!;
      expect(decoded.width, 2048, reason: '宽为长边 ⇒ 按宽缩');
      expect(decoded.height, (2048 * 2000 / 3000).round());
      expect(File(out).lengthSync(), lessThan(f.lengthSync()));
    });

    test('低档：长边 1280；竖图按**高**缩（不拉横）', () async {
      final f = _write('c.jpg', _jpeg(1200, 2400));
      final out = await c.compress(
        localPath: f.path,
        quality: PhotoUploadQuality.low,
      );
      final decoded = img.decodeImage(File(out).readAsBytesSync())!;
      expect(decoded.height, 1280);
      expect(decoded.width, (1280 * 1200 / 2400).round());
    });

    test('小图不放大：长边已小于上限 → 尺寸不变（只重编码/或原样）', () async {
      final f = _write('d.jpg', _jpeg(400, 300));
      final out = await c.compress(
        localPath: f.path,
        quality: PhotoUploadQuality.high,
      );
      final decoded = img.decodeImage(File(out).readAsBytesSync())!;
      expect(decoded.width, 400);
      expect(decoded.height, 300);
    });

    test('HEIC/RAW/视频：**原样直传**（不尝试解码，不丢内容）', () async {
      for (final name in ['e.heic', 'f.dng', 'g.mp4']) {
        final f = _write(name, const [1, 2, 3, 4]);
        final out = await c.compress(
          localPath: f.path,
          quality: PhotoUploadQuality.low,
        );
        expect(out, f.path, reason: '$name 不该被压');
        expect(f.readAsBytesSync(), const [1, 2, 3, 4]);
      }
    });

    test('认不出内容的 .jpg：原样返回（不抛、不丢）', () async {
      final f = _write('bad.jpg', const [0, 1, 2, 3, 4, 5]);
      final out = await c.compress(
        localPath: f.path,
        quality: PhotoUploadQuality.low,
      );
      expect(out, f.path);
    });
  });

  group('队列接线：压缩只影响**上传内容**，去重哈希仍用原文件', () {
    test('档位=high → uploader 收到压缩路径；hasher 收到**原路径**', () async {
      final original = _write('q.jpg', _jpeg(2400, 1600));
      final media = _FakeMedia(original.path);
      final uploader = _FakeUploader();
      final hasher = _FakeHasher();
      final compressor = _MarkerCompressor();
      final queue = PhotoBackupQueue(
        media: media,
        uploader: uploader,
        store: _MemStore(),
        hasher: hasher,
        compressor: compressor,
        snapshot: const PhotoBackupSnapshot(
          uploadQuality: PhotoUploadQuality.high,
        ),
      );
      queue.load(
        PhotoBackupPlanner.plan(
          assets: media.assets,
          doneKeys: const {},
          remote: const [],
        ),
      );
      queue.start();
      await _settle();
      expect(queue.counts.done, 1);
      expect(compressor.calls, 1);
      expect(compressor.lastQuality, PhotoUploadQuality.high);
      expect(uploader.lastLocalPath, 'compressed://${original.path}');
      expect(hasher.sampledPaths, [original.path]);
      expect(uploader.lastBytes, isNotNull);
    });

    test('档位=original → 根本不调压缩器（零开销）', () async {
      final original = _write('r.jpg', _jpeg(2400, 1600));
      final compressor = _MarkerCompressor();
      final uploader = _FakeUploader();
      final media = _FakeMedia(original.path);
      final queue = PhotoBackupQueue(
        media: media,
        uploader: uploader,
        store: _MemStore(),
        compressor: compressor,
      );
      queue.load(
        PhotoBackupPlanner.plan(
          assets: media.assets,
          doneKeys: const {},
          remote: const [],
        ),
      );
      queue.start();
      await _settle();
      expect(queue.counts.done, 1);
      expect(compressor.calls, 0);
      expect(uploader.lastLocalPath, original.path);
    });
  });
}

class _FakeMedia implements DeviceMediaLibrary {
  _FakeMedia(this.path);
  final String path;
  List<DeviceMediaAsset> get assets => [
    DeviceMediaAsset(
      id: '1',
      uri: 'content://1',
      displayName: 'q.jpg',
      size: File(path).lengthSync(),
      takenTimeMs: DateTime(2026, 9, 18).millisecondsSinceEpoch,
      modifiedTimeMs: DateTime(2026, 9, 18).millisecondsSinceEpoch,
      relativePath: 'DCIM/Camera/',
      isVideo: false,
    ),
  ];
  @override
  Future<MediaPermission> permissionStatus() async => MediaPermission.granted;
  @override
  Future<MediaPermission> ensurePermission({bool interactive = true}) async =>
      MediaPermission.granted;
  @override
  Future<List<DeviceMediaAsset>> list({
    bool includeVideos = true,
    int limit = 500,
    int offset = 0,
  }) async => assets;
  @override
  Future<String?> materialize(DeviceMediaAsset asset) async => path;
}

class _FakeUploader implements PhotoBackupUploader {
  String? lastLocalPath;
  Uint8List? lastBytes;
  @override
  Future<String> upload({
    required DeviceMediaAsset asset,
    required String localPath,
    required String targetFolderId,
    required PhotoBackupDestination destination,
    void Function(int sent, int total)? onProgress,
  }) async {
    lastLocalPath = localPath;
    lastBytes = localPath.startsWith('compressed://')
        ? Uint8List.fromList(const [9])
        : File(localPath).readAsBytesSync();
    onProgress?.call(1, 1);
    return 'unit-1';
  }
}

class _FakeHasher implements PhotoBackupHasher {
  final List<String> sampledPaths = [];
  @override
  Future<String> sampledMd5(String localPath) async {
    sampledPaths.add(localPath);
    return 'deadbeef';
  }

  @override
  Future<String> fullMd4(String localPath) async => '';
}

class _MarkerCompressor implements PhotoUploadCompressor {
  int calls = 0;
  PhotoUploadQuality? lastQuality;
  @override
  Future<String> compress({
    required String localPath,
    required PhotoUploadQuality quality,
  }) async {
    calls++;
    lastQuality = quality;
    return 'compressed://$localPath';
  }
}

class _MemStore implements PhotoBackupStore {
  PhotoBackupSnapshot _snap = const PhotoBackupSnapshot();
  @override
  Future<PhotoBackupSnapshot> load() async => _snap;
  @override
  Future<void> save(PhotoBackupSnapshot snapshot) async => _snap = snapshot;
  @override
  Future<PhotoBackupSnapshot> loadFor(PhotoBackupDestination destination) async =>
      _snap;
}
