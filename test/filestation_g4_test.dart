// G4 批次：**接口层**离线测试（146 / 219 / 223）。
//
// 三行都尽量不依赖 widget：
//   * 146 多卷识别 —— 纯函数（`archive_volumes.dart`）；
//   * 219 离线 Pin —— 纯本地清单（`file_offline_pin.dart`）；
//   * 223 USB     —— `FileStationApi.listUsbDevices` / `ejectUsbDevice`
//                    的协议形状 + 404 语义 + DTO 解析。
//
// 协议口径的**一手证据**都在对应实现的注释里（DS file 反编译 smali +
// FileStation `conf/resource` 的 `allow_other_apis` + 本会话只读真机探针）。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/archive_volumes.dart';
import 'package:synhub/src/features/files/file_offline_pin.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// USB API 在能力表里的形状（真机 `API.Info`：只注册 v1，路径 `entry.cgi`）。
const _usbTable = {
  'SYNO.Core.ExternalDevice.Storage.USB': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

FakeTransport _transport() =>
    FakeTransport({}, {...FakeTransport.table, ..._usbTable});

Future<FileStationApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return FileStationApi(api);
}

Map<String, dynamic> _call(FakeTransport t) => t.calls.last;

void main() {
  // ------------------------------------------------------------ 146 多卷

  group('146 分卷压缩包识别', () {
    test('RAR 新式分卷 .partN.rar：第 1 卷可解压、第 N 卷要改选', () {
      final first = detectArchiveVolume('movie.part1.rar')!;
      expect(first.kind, ArchiveVolumeKind.rarPart);
      expect(first.index, 1);
      expect(first.isFirst, isTrue);
      expect(first.firstVolumeName, 'movie.part1.rar');

      final later = detectArchiveVolume('movie.part12.rar')!;
      expect(later.index, 12);
      expect(later.isFirst, isFalse);
      // WinRAR 在分卷 ≥10 个时把卷号补零（part01…part12），
      // 所以从 part12 反推第 1 卷得到的应该是 part01
      expect(later.firstVolumeName, 'movie.part01.rar');
      expect(needsVolumeHint('movie.part12.rar'), isTrue);
      expect(needsVolumeHint('movie.part1.rar'), isFalse);
    });

    test('补零宽度保留：part01 → 第 1 卷仍然是 part01（不是 part1）', () {
      expect(
        detectArchiveVolume('a.part07.rar')!.firstVolumeName,
        'a.part01.rar',
      );
    });

    test('RAR 老式分卷 .rNN：.r00 是第 2 卷，第 1 卷是 .rar', () {
      final v = detectArchiveVolume('old.r00')!;
      expect(v.kind, ArchiveVolumeKind.rarOld);
      expect(v.index, 2);
      expect(v.firstVolumeName, 'old.rar');
      expect(needsVolumeHint('old.r00'), isTrue);
    });

    test('数字分卷 .001/.002：.001 是第 1 卷（isFirst）', () {
      final v1 = detectArchiveVolume('pkg.7z.001')!;
      expect(v1.kind, ArchiveVolumeKind.numeric);
      expect(v1.index, 1);
      expect(v1.isFirst, isTrue);
      expect(isFirstVolume('pkg.7z.001'), isTrue);

      final v2 = detectArchiveVolume('pkg.7z.002')!;
      expect(v2.index, 2);
      expect(v2.firstVolumeName, 'pkg.7z.001');
      expect(needsVolumeHint('pkg.7z.002'), isTrue);
    });

    test('ZIP 分卷 .z01/.z02', () {
      final v = detectArchiveVolume('doc.z02')!;
      expect(v.kind, ArchiveVolumeKind.zip);
      expect(v.index, 2);
      expect(v.firstVolumeName, 'doc.z01');
      expect(detectArchiveVolume('doc.z01')!.isFirst, isTrue);
    });

    test('普通文件一律不误判（含已支持的 .rar/.7z 单卷）', () {
      for (final name in [
        'a.rar',
        'a.7z',
        'a.zip',
        'a.txt',
        'a.001.txt',
        'notes.mp3',
        'part1.rar', // 没有基名 → 不是分卷
        'a.001.txt',
      ]) {
        final v = detectArchiveVolume(name);
        expect(v, isNull, reason: '$name 不该被识别成分卷');
      }
    });

    test('4 位卷号（.0001）也是数字分卷的第 1 卷', () {
      final v = detectArchiveVolume('frames.0001')!;
      expect(v.kind, ArchiveVolumeKind.numeric);
      expect(v.index, 1);
      expect(v.isFirst, isTrue);
    });
  });

  // ------------------------------------------------------------ 223 USB

  group('223 USB 外接设备', () {
    test(
      'list：api/method/version=1 + additional=partitions（v1 逗号口径）',
      () async {
        final t = _transport();
        t.responses['SYNO.Core.ExternalDevice.Storage.USB.list'] = {
          'devices': [
            {
              'dev_id': 'usb1',
              'dev_title': 'SanDisk Cruzer',
              'partitions': [
                {
                  'name_id': 'usb1p1',
                  'partition_title': 'usbshare1',
                  'share_name': 'usbshare1',
                  'filesystem': 'vfat',
                  'status': 'normal',
                  'total_size_mb': '30436',
                  'used_size_mb': '124',
                },
              ],
            },
          ],
        };
        final fs = await _api(t);
        final r = await fs.listUsbDevices();

        final call = _call(t);
        expect(call['api'], 'SYNO.Core.ExternalDevice.Storage.USB');
        expect(call['method'], 'list');
        expect(call['version'], '1');
        expect(call['additional'], 'partitions');

        expect(r.notFound, isFalse);
        expect(r.devices, hasLength(1));
        expect(r.devices.single.devId, 'usb1');
        expect(r.devices.single.title, 'SanDisk Cruzer');
        final p = r.devices.single.partitions.single;
        expect(p.shareName, 'usbshare1');
        expect(p.filesystem, 'vfat');
        // 字符串数字也要解析得动（官方 vo 里就是 String）
        expect(p.totalSizeMb, 30436);
        expect(p.usedSizeMb, 124);
      },
    );

    test('list 回 404 → 空列表 + notFound=true（不抛）', () async {
      final t = _transport();
      t.failures['SYNO.Core.ExternalDevice.Storage.USB.list'] = 404;
      final fs = await _api(t);
      final r = await fs.listUsbDevices();
      expect(r.devices, isEmpty);
      expect(r.isEmpty, isTrue);
      expect(r.notFound, isTrue);
    });

    test('list 回 105（无权限）→ 照原样抛，不当成"没有设备"', () async {
      final t = _transport();
      t.failures['SYNO.Core.ExternalDevice.Storage.USB.list'] = 105;
      final fs = await _api(t);
      await expectLater(
        fs.listUsbDevices(),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 105)),
      );
    });

    test('list：响应里没有 devices/items 也不崩（当空表）', () async {
      final t = _transport();
      t.responses['SYNO.Core.ExternalDevice.Storage.USB.list'] = const {};
      final fs = await _api(t);
      final r = await fs.listUsbDevices();
      expect(r.devices, isEmpty);
      expect(r.notFound, isFalse);
    });

    test('eject：method=eject + version=1 + dev_id 原样回传', () async {
      final t = _transport();
      t.responses['SYNO.Core.ExternalDevice.Storage.USB.eject'] = const {};
      final fs = await _api(t);
      await fs.ejectUsbDevice('usb1');
      final call = _call(t);
      expect(call['method'], 'eject');
      expect(call['version'], '1');
      expect(call['dev_id'], 'usb1');
    });
  });

  // ------------------------------------------------------------ 219 离线 Pin

  group('219 离线文件（本地清单）', () {
    OfflinePinEntry entry(String path, {int at = 0, String local = ''}) =>
        OfflinePinEntry(
          path: path,
          name: path.split('/').last,
          size: 1024,
          pinnedAt: at,
          localPath: local,
        );

    test('JSON 往返：字段名与官方 Pin（path/name/size/local_path）一致', () {
      final e = entry('/home/a.txt', at: 100, local: '/tmp/a.txt');
      final back = OfflinePinEntry.fromJson(
        jsonDecode(jsonEncode(e.toJson())),
      )!;
      expect(back.path, '/home/a.txt');
      expect(back.name, 'a.txt');
      expect(back.size, 1024);
      expect(back.pinnedAt, 100);
      expect(back.localPath, '/tmp/a.txt');
      expect(back.hasLocalCopy, isTrue);
    });

    test('没有 path 的脏数据被丢掉（不崩）', () {
      expect(OfflinePinEntry.fromJson(const {'name': 'x'}), isNull);
      expect(OfflinePinEntry.fromJson('nonsense'), isNull);
    });

    test('pin / isPinned / toggle / unpin 都落盘', () async {
      final store = MemoryOfflinePinStore();
      final c = ProviderContainer(
        overrides: [offlinePinStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final n = c.read(offlinePinProvider.notifier);

      expect(n.isPinned('/home/a.txt'), isFalse);
      expect(await n.toggle(entry('/home/a.txt', at: 1)), isTrue);
      expect(n.isPinned('/home/a.txt'), isTrue);
      expect(store.items, hasLength(1));

      // 再 toggle 一次 = 取消
      expect(await n.toggle(entry('/home/a.txt', at: 1)), isFalse);
      expect(store.items, isEmpty);

      await n.pin(entry('/home/b.txt', at: 2));
      await n.unpin('/home/b.txt');
      expect(c.read(offlinePinProvider), isEmpty);
      expect(store.items, isEmpty);
    });

    test('preload 把落盘清单读回内存，并按登记时间倒序', () async {
      final store = MemoryOfflinePinStore([
        entry('/home/old.txt', at: 10),
        entry('/home/new.txt', at: 99),
      ]);
      final c = ProviderContainer(
        overrides: [offlinePinStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final n = c.read(offlinePinProvider.notifier);
      expect(c.read(offlinePinProvider), isEmpty);
      await n.preload();
      final got = c.read(offlinePinProvider);
      expect(got.map((e) => e.path), ['/home/new.txt', '/home/old.txt']);
    });

    test('同一路径重复 pin 不会重复计数（以最后一次为准）', () async {
      final store = MemoryOfflinePinStore();
      final c = ProviderContainer(
        overrides: [offlinePinStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final n = c.read(offlinePinProvider.notifier);
      await n.pin(entry('/home/a.txt', at: 1));
      await n.pin(entry('/home/a.txt', at: 5));
      expect(c.read(offlinePinProvider), hasLength(1));
      expect(c.read(offlinePinProvider).single.pinnedAt, 5);
    });

    test('setLocalPath 回填本地副本（对应官方 mLocalPath）', () async {
      final store = MemoryOfflinePinStore([entry('/home/a.txt', at: 1)]);
      final c = ProviderContainer(
        overrides: [offlinePinStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final n = c.read(offlinePinProvider.notifier);
      await n.preload();
      await n.setLocalPath('/home/a.txt', '/tmp/cache/a.txt');
      expect(c.read(offlinePinProvider).single.hasLocalCopy, isTrue);
      expect(store.items.single.localPath, '/tmp/cache/a.txt');
    });

    test('clear 清空内存与落盘', () async {
      final store = MemoryOfflinePinStore([entry('/home/a.txt', at: 1)]);
      final c = ProviderContainer(
        overrides: [offlinePinStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final n = c.read(offlinePinProvider.notifier);
      await n.preload();
      await n.clear();
      expect(c.read(offlinePinProvider), isEmpty);
      expect(store.items, isEmpty);
    });

    test('offlinePinnedPathsProvider 反映清单路径集合', () async {
      final store = MemoryOfflinePinStore([entry('/home/a.txt', at: 1)]);
      final c = ProviderContainer(
        overrides: [offlinePinStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      await c.read(offlinePinProvider.notifier).preload();
      expect(c.read(offlinePinnedPathsProvider), {'/home/a.txt'});
    });
  });
}
