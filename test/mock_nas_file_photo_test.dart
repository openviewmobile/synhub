// Mock NAS 端到端验证 · **文件**（`lib/src/data/filestation_api.dart`）与
// **相册**（`lib/src/data/foto_api.dart`）模块。
//
// 文件写操作（删除 / 复制移动 / 新建 / 重命名）全部走**真实 HTTP**，
// 并断言 mock 内存文件树真的变了。全部只连进程内 mock，**不碰真实 NAS**。

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/foto_api.dart';

import 'support/mock_nas_harness.dart';

Future<MockNasHarness> _bootFile() =>
    startMockNasHarness(declaredApis: const {'file'});

Future<MockNasHarness> _bootPhoto() =>
    startMockNasHarness(declaredApis: const {'photo'});

void main() {
  group('文件 · 写操作', () {
    test('137 M17 移动文件（CopyMove/start remove_src:true）', () async {
      final h = await _bootFile();
      addTearDown(h.dispose);
      final fs = FileStationApi(h.api);

      await fs.startCopyMove(
        paths: ['/home/Books/mock-clip.mp4'],
        destFolderPath: '/mock-share',
        removeSrc: true,
      );

      expect(h.store.fs.containsKey('/home/Books/mock-clip.mp4'), isFalse);
      expect(h.store.fs.containsKey('/mock-share/mock-clip.mp4'), isTrue);

      final dest = await fs.listFolder(folderPath: '/mock-share');
      expect(dest.entries.map((e) => e.name), contains('mock-clip.mp4'));
      final src = await fs.listFolder(folderPath: '/home/Books');
      expect(src.entries.map((e) => e.name), isNot(contains('mock-clip.mp4')));
    });

    test('138 M18 跨共享复制（remove_src:false 源仍在）', () async {
      final h = await _bootFile();
      addTearDown(h.dispose);
      final fs = FileStationApi(h.api);

      await fs.startCopyMove(
        paths: ['/home/Books/session-expiry.txt'],
        destFolderPath: '/mock-share',
        removeSrc: false,
      );

      expect(h.store.fs.containsKey('/home/Books/session-expiry.txt'), isTrue);
      expect(h.store.fs.containsKey('/mock-share/session-expiry.txt'), isTrue);
    });

    test('134 删除进回收站（Delete/start → /<share>/#recycle）', () async {
      final h = await _bootFile();
      addTearDown(h.dispose);
      final fs = FileStationApi(h.api);

      await fs.deleteItems(['/home/Books/session-expiry.txt']);

      final src = await fs.listFolder(folderPath: '/home/Books');
      expect(
        src.entries.map((e) => e.name),
        isNot(contains('session-expiry.txt')),
      );
      expect(
        h.store.fs.containsKey('/home/#recycle/session-expiry.txt'),
        isTrue,
      );
    });

    test('172 M42 回收站浏览（List/list 打 `#recycle` 路径）', () async {
      final h = await _bootFile();
      addTearDown(h.dispose);
      final fs = FileStationApi(h.api);

      await fs.deleteItems(['/home/Books/session-expiry.txt']);
      final recycle = await fs.listFolder(folderPath: '/home/#recycle');

      final names = recycle.entries.map((e) => e.name);
      expect(names, contains('session-expiry.txt'));
      // 回收站条目路径可被 `RecyclePath` 识别（客户端还原逻辑的输入前提）
      final entry = recycle.entries.firstWhere(
        (e) => e.name == 'session-expiry.txt',
      );
      expect(entry.path, contains('#recycle'));
    });

    test('173 M43 从回收站还原（CopyMove/start restore_from_recycle_bin）', () async {
      final h = await _bootFile();
      addTearDown(h.dispose);
      final fs = FileStationApi(h.api);

      await fs.deleteItems(['/home/Books/session-expiry.txt']);
      await fs.restoreFromRecycleBin(
        paths: ['/home/#recycle/session-expiry.txt'],
        destFolderPath: '/home/Books',
      );

      expect(h.store.fs.containsKey('/home/Books/session-expiry.txt'), isTrue);
      expect(
        h.store.fs.containsKey('/home/#recycle/session-expiry.txt'),
        isFalse,
      );
    });

    test('173b M43 清空回收站（Core.RecycleBin/start）', () async {
      final h = await _bootFile();
      addTearDown(h.dispose);
      final fs = FileStationApi(h.api);

      await fs.deleteItems(['/home/Books/session-expiry.txt']);
      await fs.purgeRecycleBin('home');

      expect(
        h.store.fs.containsKey('/home/#recycle/session-expiry.txt'),
        isFalse,
      );
      final recycle = await fs.listFolder(folderPath: '/home/#recycle');
      expect(
        recycle.entries.map((e) => e.name),
        isNot(contains('session-expiry.txt')),
      );
    });

    test('135 M15 回收站内永久删除（Delete/delete）', () async {
      final h = await _bootFile();
      addTearDown(h.dispose);
      final fs = FileStationApi(h.api);

      await fs.deleteItems(['/home/Books/session-expiry.txt']);
      await fs.deletePermanently(['/home/#recycle/session-expiry.txt']);

      expect(
        h.store.fs.containsKey('/home/#recycle/session-expiry.txt'),
        isFalse,
      );
    });

    test('139 M19 新建文件夹（CreateFolder/create）', () async {
      final h = await _bootFile();
      addTearDown(h.dispose);
      final fs = FileStationApi(h.api);

      await fs.createFolder(folderPath: '/home/Books', name: '新目录');
      expect(h.store.fs['/home/Books/新目录']?.isDir, isTrue);

      final list = await fs.listFolder(folderPath: '/home/Books');
      expect(list.entries.map((e) => e.name), contains('新目录'));
    });

    test('133 M13 重命名（Rename/rename 平行数组）', () async {
      final h = await _bootFile();
      addTearDown(h.dispose);
      final fs = FileStationApi(h.api);

      await fs.rename(
        path: '/home/Books/session-expiry.txt',
        name: 'expired.txt',
      );
      expect(h.store.fs.containsKey('/home/Books/session-expiry.txt'), isFalse);
      expect(h.store.fs.containsKey('/home/Books/expired.txt'), isTrue);
    });

    test('205 M58 后台任务列表（mock 的文件任务同步完成 → 恒空）', () async {
      final h = await _bootFile();
      addTearDown(h.dispose);
      final fs = FileStationApi(h.api);

      await fs.deleteItems(['/home/Books/session-expiry.txt']);
      final tasks = await fs.listBackgroundTasks();
      // mock 同步完成，因此列表为空正是"任务已即时生效"的判据
      expect(tasks.tasks, isEmpty);
    });
  });

  group('相册 · 端到端', () {
    test('P3 时间线增量分页（Browse.Item/list offset+limit）', () async {
      final h = await _bootPhoto();
      addTearDown(h.dispose);
      final foto = FotoApi(h.api);

      final first = await foto.timeline(offset: 0, limit: 1);
      final second = await foto.timeline(offset: 1, limit: 1);
      expect(first.length, 1);
      expect(second.length, 1);
      expect(first.first.id, isNot(second.first.id));

      final all = await foto.timeline(offset: 0, limit: 50);
      expect(all.length, 2);
      // 默认按 takentime 倒序
      expect(all.first.time >= all.last.time, isTrue);
    });

    test('P10 收藏标记（Browse.Item/set_favorite + favorite 过滤）', () async {
      final h = await _bootPhoto();
      addTearDown(h.dispose);
      final foto = FotoApi(h.api);

      final before = await foto.favorites();
      expect(before.map((p) => p.id), ['1']);
      expect(before.first.isFavorite, isTrue);

      await foto.setFavorite(['2'], true);
      expect(h.store.photos['2']!.favorite, isTrue);
      final after = await foto.favorites();
      expect(after.map((p) => p.id), containsAll(['1', '2']));

      await foto.setFavorite(['1'], false);
      expect(h.store.photos['1']!.favorite, isFalse);
      expect((await foto.favorites()).map((p) => p.id), ['2']);
    });

    test('P28 批量删除照片（Browse.Item/delete）', () async {
      final h = await _bootPhoto();
      addTearDown(h.dispose);
      final foto = FotoApi(h.api);

      final failed = await foto.deleteItems(['1', '2']);
      expect(failed, isEmpty);
      expect(h.store.photos.containsKey('1'), isFalse);
      expect(h.store.photos.containsKey('2'), isFalse);
      expect(await foto.timeline(), isEmpty);
    });

    test('P32 批量移动 / 复制到文件夹（Browse.Item move|copy）', () async {
      final h = await _bootPhoto();
      addTearDown(h.dispose);
      final foto = FotoApi(h.api);

      final moveFailed = await foto.moveItems(
        itemIds: ['1'],
        targetFolderId: '11',
      );
      expect(moveFailed, isEmpty);
      expect(h.store.photos['1']!.folderId, '11');

      final copyFailed = await foto.copyItems(
        itemIds: ['2'],
        targetFolderId: '11',
      );
      expect(copyFailed, isEmpty);
      final copied = h.store.photos.values.where((p) => p.folderId == '11');
      expect(copied.length, 2);
    });

    test('P33 从相册移除（Browse.NormalAlbum/delete_item）', () async {
      final h = await _bootPhoto();
      addTearDown(h.dispose);
      final foto = FotoApi(h.api);

      expect((await foto.albums()).map((a) => a.id), contains('a-1'));

      await foto.removeItemsFromAlbum(albumId: 'a-1', itemIds: ['1', '2']);
      expect(h.store.photos['1']!.albumIds, isNot(contains('a-1')));
      expect(await foto.albumItems('a-1'), isEmpty);
    });

    test('P9 相册默认排序读写（Album get|set_album_list_order）', () async {
      final h = await _bootPhoto();
      addTearDown(h.dispose);
      final foto = FotoApi(h.api);

      final before = await foto.getAlbumListOrder();
      expect(before.sortBy, 'create_time');

      await foto.setAlbumListOrder(sortBy: 'album_name', sortDirection: 'asc');
      final after = await foto.getAlbumListOrder();
      expect(after.sortBy, 'album_name');
      expect(after.sortDirection, 'asc');
      expect(h.store.albumListOrderBy, 'album_name');
    });
  });
}
