// Mock NAS 端到端验证 · **下载模块**（`lib/src/data/download_station.dart`）。
//
// 每个 `test` 对应 `docs/parity-final-gap-table.md` 里一行 🟡；写操作额外断言
// mock 内存状态真的变了。全部只连进程内 mock，**不碰任何真实 NAS**。

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/data/dto/download_task_dto.dart';

import 'support/mock_nas_harness.dart';

Future<MockNasHarness> _boot() =>
    startMockNasHarness(declaredApis: const {'download'});

void main() {
  group('下载 · 列表 / 详情', () {
    test('A11 批量取任务详情（Task/get {id:[…]}）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final tasks = await ds.getTasks(['ds-1', 'ds-2']);
      expect(tasks.map((t) => t.id), containsAll(['ds-1', 'ds-2']));
      expect(tasks.length, 2);
    });

    test('A3 进度 / 速率 / 剩余时间字段形状（Task/list transfer）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final task = (await ds.getTask('ds-1'))!;
      expect(task.size, 4096);
      expect(task.transfer.sizeDownloaded, 1024);
      expect(task.transfer.speedDownload, 512);
      expect(task.progress, closeTo(0.25, 0.0001));
      // eta = (4096-1024)/512 = 6s
      expect(task.etaSeconds, 6);
      expect(task.isFinished, isFalse);
    });

    test('A5 任务详情（additional.detail：目的地/优先级/URI）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final task = (await ds.getTask('ds-1'))!;
      expect(task.detail.destination, '/volume1/downloads');
      expect(task.detail.priority, 'normal');
      expect(task.detail.uri, contains('mock-linux.iso'));
      expect(task.type, 'http');
    });

    test('A9 任务搜索 / 关键字（服务端 keyword 过滤）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final page = await ds.listTasks(keyword: 'linux');
      expect(page.items.map((t) => t.id), ['ds-1']);
      expect(page.total, 1);
    });

    test('A10 列表排序（sort_by + order）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final asc = await ds.listTasks(sortBy: 'title', descending: false);
      final titles = asc.items.map((t) => t.title).toList();
      final sorted = [...titles]..sort();
      expect(titles, sorted);
    });
  });

  group('下载 · 只读明细（Tracker / Peer / File / NZB / 统计）', () {
    test('A7 Tracker 列表（Task.BT.Tracker/list）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final page = await ds.listTrackers('ds-2');
      expect(page.items, isNotEmpty);
      expect(page.items.first.url, contains('tracker.example.invalid'));
      expect(page.total, page.items.length);
    });

    test('A8 Peer 列表（Task.BT.Peer/list）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final page = await ds.listPeers('ds-2');
      expect(page.items, isNotEmpty);
      expect(page.items.first.ip, '10.0.0.9');
    });

    test('A6 任务内文件清单（Task.BT.File/list）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final page = await ds.listFiles('ds-2');
      expect(page.items.map((f) => f.name), contains('mock.bin'));
      expect(page.items.length, 2);
    });

    test('A4 顶部总速率（Task.Statistic/get）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final stat = await ds.statistic();
      expect(stat.downloadRate, 512);
    });

    test('C10 默认下载目录（Settings.Location/get）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);
      expect(await ds.defaultDestination(), '/volume1/downloads');
    });

    test('F5 NZB 日志（Task.NZB.Log/get）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);
      expect((await ds.nzbLog('ds-3')).log, contains('mock nzb log'));
    });

    test('F6 NZB 文件清单（Task.NZB.File/list）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);
      final page = await ds.nzbFiles('ds-3');
      expect(page.items.map((f) => f.name), contains('mock.nzb.001'));
    });

    test('E2 RSS 条目列表（RSS.Item/list feed_id+分页）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final page = await ds.rssItemList(feedId: 'feed-1');
      expect(page.items.map((i) => i.title), contains('Mock RSS Item A'));
      expect(page.total, 2);

      final first = await ds.rssItemList(feedId: 'feed-1', limit: 1);
      expect(first.items.length, 1);
    });

    test('E3 更新订阅（RSS.Feed updateall 真的落 is_updating）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      expect((await ds.rssFeedList()).items.first.isUpdating, isTrue);
      await ds.rssFeedUpdateAll();
      expect((await ds.rssFeedList()).items.first.isUpdating, isFalse);
      expect(h.store.rssFeeds['feed-1']!['is_updating'], isFalse);
    });

    test('E1 RSS 订阅源列表（RSS.Feed/list）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final page = await ds.rssFeedList();
      expect(page.items.map((f) => f.title), contains('Mock Feed'));
    });
  });

  group('下载 · 写操作（状态真的改）', () {
    test('B1 暂停 / 恢复单任务（Task/pause|resume）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      await ds.pauseTasks(['ds-1']);
      expect((await ds.getTask('ds-1'))!.status, DsTaskStatus.paused);
      expect(h.store.downloadTasks['ds-1']!.status, DsTaskStatus.paused);

      await ds.resumeTasks(['ds-1']);
      expect((await ds.getTask('ds-1'))!.status, DsTaskStatus.downloading);
    });

    test('B2 删除单任务（Task/delete）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      await ds.deleteTasks(['ds-1']);
      final page = await ds.listTasks();
      expect(page.items.map((t) => t.id), isNot(contains('ds-1')));
      expect(h.store.downloadTasks.containsKey('ds-1'), isFalse);
    });

    test('B4 全部暂停 / 全部恢复（pause_condition|resume_condition）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      await ds.pauseAll();
      for (final t in (await ds.listTasks()).items) {
        expect(t.status, DsTaskStatus.paused, reason: t.id);
      }

      await ds.resumeAll();
      expect((await ds.getTask('ds-1'))!.status, DsTaskStatus.downloading);
    });

    test('B5 清除已完成（delete_condition {status:[5]}）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      await ds.deleteCondition(statuses: [DsTaskStatus.finished]);

      final ids = (await ds.listTasks()).items.map((t) => t.id);
      expect(ids, isNot(contains('ds-2'))); // 已完成 → 被清
      expect(ids, contains('ds-1')); // 下载中 → 保留
      expect(h.store.downloadTasks.containsKey('ds-2'), isFalse);
    });

    test('B6 结束未完成任务（Task/delete force_complete:true）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      await ds.deleteTasks(['ds-1'], forceComplete: true);
      expect(h.store.downloadTasks.containsKey('ds-1'), isFalse);
    });

    test('B7 任务优先级（Task.BT/set priority）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final before = await ds.getBtSettings('ds-2');
      await ds.setBtSettings('ds-2', before.copyWith(priority: 'high'));
      expect((await ds.getBtSettings('ds-2')).priority, 'high');
      expect(h.store.downloadTasks['ds-2']!.priority, 'high');
    });

    test('B9 单任务 BT 限速（Task.BT get→set 回读）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final before = await ds.getBtSettings('ds-2');
      expect(before.maxDownloadRate, 0);
      await ds.setBtSettings(
        'ds-2',
        before.copyWith(maxDownloadRate: 512, maxUploadRate: 64),
      );

      final after = await ds.getBtSettings('ds-2');
      expect(after.maxDownloadRate, 512);
      expect(after.maxUploadRate, 64);
      expect(h.store.downloadTasks['ds-2']!.maxDownloadRate, 512);
    });

    test('B8 改任务目的地 / 优先级（Task/edit）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      await ds.editTask(['ds-1'], destination: '/volume1/media');
      expect((await ds.getTask('ds-1'))!.detail.destination, '/volume1/media');
      expect(h.store.downloadTasks['ds-1']!.destination, '/volume1/media');
    });

    test('C1 URL 建任务（Task/create type:url）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final known = (await ds.listTasks()).items.map((t) => t.id).toSet();
      await ds.createUrlTask(urls: ['https://example.invalid/new-file.zip']);

      final newest = await ds.newestTaskId(known);
      expect(newest, isNotNull);
      final task = (await ds.getTask(newest!))!;
      expect(task.title, 'new-file.zip');
      expect(task.type, 'http');
      expect(task.status, DsTaskStatus.downloading);
    });

    test('C3 磁力链接建任务（magnet:? → bt 类型）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final known = (await ds.listTasks()).items.map((t) => t.id).toSet();
      await ds.createUrlTask(urls: ['magnet:?xt=urn:btih:MOCKMAGNET']);
      final newest = await ds.newestTaskId(known);
      expect(newest, isNotNull);
      expect((await ds.getTask(newest!))!.type, 'bt');
    });

    test('C2 FTP 账号/密码（username+password 真的落到任务）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final known = (await ds.listTasks()).items.map((t) => t.id).toSet();
      await ds.createUrlTask(
        urls: ['ftp://example.invalid/pub/file.bin'],
        username: 'ftpuser',
        password: 'ftp pass',
      );
      final newest = await ds.newestTaskId(known);
      expect(newest, isNotNull);
      expect(h.store.downloadTasks[newest!]!.username, 'ftpuser');
      expect(h.store.downloadTasks[newest]!.password, 'ftp pass');
    });

    test('C11 建任务带解压密码（extract_password）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final known = (await ds.listTasks()).items.map((t) => t.id).toSet();
      await ds.createUrlTask(
        urls: ['https://example.invalid/locked.zip'],
        extractPassword: 's3cret',
      );
      final newest = await ds.newestTaskId(known);
      expect(newest, isNotNull);
      expect(h.store.downloadTasks[newest!]!.extractPassword, 's3cret');
    });

    test('C13 种子选择文件流程（create_list + Task.List get/download）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final created = await ds.createUrlTask(
        urls: ['https://example.invalid/pick.torrent'],
        createList: true,
      );
      expect(created.listId, isNotNull);

      final list = await ds.getCreateList(created.listId!);
      expect(list.files, isNotEmpty);
      expect(list.files.first.name, 'pick.torrent');

      await ds.downloadCreateList(listId: created.listId!);
      expect(h.store.createLists.containsKey(created.listId!), isFalse);
    });

    test('C13b 放弃选择清掉临时清单（Task.List/delete）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final created = await ds.createUrlTask(
        urls: ['https://example.invalid/drop.torrent'],
        createList: true,
      );
      await ds.deleteCreateList(created.listId!);
      expect(h.store.createLists.containsKey(created.listId!), isFalse);
    });

    test('C14 验证码任务的读取与提交（Captcha list/set）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      expect(await ds.captchaTaskIds(), contains('ds-4'));

      await ds.setCaptcha(taskId: 'ds-4', code: 'ABCD');
      expect(await ds.captchaTaskIds(), isNot(contains('ds-4')));
      final task = (await ds.getTask('ds-4'))!;
      expect(task.status, DsTaskStatus.downloading);
    });

    test('D3 搜索站点列表（下载模块在用的 getModule 家族）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final modules = await ds.btSearchModules();
      expect(modules.map((m) => m.id), contains('mock-module'));
      expect(modules.firstWhere((m) => m.id == 'mock-module').enabled, isTrue);
    });

    test('D5 停止 BT 搜索（BTSearch/stop）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final ds = DownloadStationApi(h.api);

      final id = await ds.btSearchStart(keyword: 'ubuntu');
      expect(id, isNotEmpty);
      expect(await ds.btSearchStop(id), isTrue);
    });
  });
}
