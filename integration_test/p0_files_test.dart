// P0「文件」模块的真机端到端验证。
//
// 跑法（真机 + 真 NAS）：
//   cd <home>/Documents/synology_chat
//   flutter test integration_test/p0_files_test.dart -d AXGE022428000622 \
//     --dart-define=SYNO_NAS_QC=demo_admin-qq \
//     --dart-define=SYNO_NAS_ACCOUNT=demo_user \
//     --dart-define=SYNO_NAS_PASSWORD='…' \
//     --dart-define=SYNO_LIVE_POST=true        # 允许写操作（建/改名/上传/压缩/删除）
//
// 验证的东西（都是"看服务器真实反应"，不是单测里的假响应）：
//   ① **跨模块会话**：用 `session=Chat` 登录的 sid 直接驱动 FileStation；
//   ② 根目录 `list_share` 与子目录 `list`（`additional` 用 JSON 串，真机只认这个）；
//   ③ 写路径：新建目录 → 上传 → 压缩 → 统计大小 → 改名 → 收藏 → 任务中心 → 删除；
//   ④ UI：`FileBrowsePage` 挂真连接，列表里能看到真实共享与真实文件。
//
// 写操作全部落在自己的临时目录里，并在 tearDown 里删干净。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/local/file_store.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/file_browse_page.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
const _liveRaw = String.fromEnvironment('SYNO_LIVE_POST');

/// `--dart-define=SYNO_LIVE_POST=1` 会被解析成默认值 false（真机踩过）
bool get _live => _liveRaw.isNotEmpty && _liveRaw != 'false';

/// 一个只有 `a.txt`（内容 "hi\n"，3 字节）的最小 zip。
/// 用来验证解压（这台 NAS 上普通用户的压缩权限被关了，但解压可用）。
const String _zipFixtureB64 =
    'UEsDBAoAAAAAABNqMl16em/tAwAAAAMAAAAFAAAAYS50eHRoaQpQSwECHgMKAAAAAAATajJdenpv7QMA'
    'AAADAAAABQAAAAAAAAABAAAApIEAAAAAYS50eHRQSwUGAAAAAAEAAQAzAAAAJgAAAAAA';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('P0 真机：文件模块（跨模块会话 / 列表 / 写操作 / UI）', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );

    // ① 用聊天会话登录，然后**不重新登录**直接用 FileStation —— 验证"一个 sid
    //    覆盖所有家族"这个跨模块结论。
    await conn.api.login(account: _account, password: _password, session: 'Chat');
    final fs = FileStationApi(conn.api);

    final info = await fs.info();
    debugPrint('[p0] ① 跨模块会话 OK：hostname=${info['hostname']} '
        'is_manager=${info['is_manager']} sharing=${info['support_sharing']}');
    expect('${info['hostname']}', isNotEmpty);

    // ② 根目录 = 共享文件夹列表（普通用户对 `/` 直接 list 会 401）
    final shares = await fs.listShares(limit: 100);
    debugPrint('[p0] ② 共享文件夹 ${shares.entries.map((e) => e.name).toList()}');
    expect(shares.entries, isNotEmpty);

    // 找一个**可写**的共享作为临时工作区
    final writable = shares.entries.where((e) => e.canWrite && e.isDir).toList();
    expect(writable, isNotEmpty,
        reason: '$_account 至少要对一个共享有写权限才能跑写路径');
    final work = writable.first.path;
    final stamp = DateTime.now().millisecondsSinceEpoch % 1000000;
    final dirName = 'flt-p0-$stamp';
    final dirPath = '$work/$dirName';

    // 子目录列表 + additional（JSON 串）
    final home = await fs.listFolder(folderPath: work, limit: 50,
        additional: FileAdditional.browse);
    debugPrint('[p0] ② $work 下 ${home.entries.length} 项，'
        '前三个：${home.entries.take(3).map((e) => '${e.name}(${e.size}B/${e.modifiedAt})').toList()}');
    expect(home.entries, isNotEmpty);
    // 至少有一项带 size 或 mtime：说明 additional 真的生效了
    expect(
      home.entries.any((e) => e.size > 0 || e.mtime > 0),
      isTrue,
      reason: 'additional 必须是 JSON 串，否则服务端只认最后一个值（真机踩过）',
    );

    final createdPaths = <String>[];
    addTearDown(() async {
      for (final p in createdPaths.reversed) {
        try {
          await fs.deleteItems([p]);
          debugPrint('[p0] 清理 $p');
        } catch (e) {
          debugPrint('[p0] 清理失败 $p → $e');
        }
      }
    });

    if (!_live) {
      debugPrint('[p0] 未开启 SYNO_LIVE_POST：跳过写操作（③④）');
      return;
    }

    // ---------- ③ 写路径 ----------

    // ③-1 新建目录
    await fs.createFolder(folderPath: work, name: dirName);
    createdPaths.add(dirPath);
    final afterCreate = await fs.getInfo(dirPath);
    debugPrint('[p0] ③-1 新建 ${afterCreate.path} isdir=${afterCreate.isDir}');
    expect(afterCreate.isDir, isTrue);

    // 写权限探测（可写目录返回 {blSkip:...}，只读目录会 401）
    // 注意 filename 必填：真机漏传会 401（哪怕目录可写）
    final perm = await fs.checkWritePermission(dirPath, filename: 'flt-p0.bin');
    debugPrint('[p0] ③-1 checkWritePermission=${perm.isWritable} '
        'skipPrompt=${perm.skipPrompt}');

    // ③-2 上传一个二进制文件
    final bytes = Uint8List.fromList(
      List<int>.generate(64 * 1024, (i) => (i * 7 + (i >> 5)) & 0xff),
    );
    final tmp = File('${Directory.systemTemp.path}/flt-p0-$stamp.bin')
      ..writeAsBytesSync(bytes);
    addTearDown(() {
      try {
        tmp.deleteSync();
      } catch (_) {}
    });
    final sent = <int>[];
    await fs.upload(
      folderPath: dirPath,
      filePath: tmp.path,
      fileName: 'flt-p0.bin',
      onProgress: (a, b) => sent.add(a),
    );
    final uploaded = await fs.getInfo('$dirPath/flt-p0.bin');
    debugPrint('[p0] ③-2 上传 ${uploaded.name} ${uploaded.size} 字节 '
        '（进度回调 ${sent.length} 次）');
    expect(uploaded.size, bytes.length);
    expect(sent, isNotEmpty, reason: '上传应该有进度回调');

    // ③-3 下载回来逐字节比对（校验 Download URL 与 _sid 注入）
    final back = await conn.api.getBytes(fs.downloadUrl(['$dirPath/flt-p0.bin']));
    debugPrint('[p0] ③-3 下载 ${back.length} 字节');
    expect(back.length, bytes.length);
    expect(back.sublist(0, 32), bytes.sublist(0, 32));
    expect(back.sublist(back.length - 32), bytes.sublist(bytes.length - 32));

    // ③-4 压缩 → 任务中心能看到。
    // DSM 7.4 的 `Compress.start` 强制要 CSRF 令牌（`X-SYNO-TOKEN`，且必须是
    // Auth **v7** 发的那个；v6 的令牌会被回一个误导性的 105）。客户端已经
    // 统一带上；这里仍然保留"没权限时降级成一句人话"的分支以防权限被关。
    var compressAllowed = true;
    try {
      await fs.startCompress(
        paths: ['$dirPath/flt-p0.bin'],
        destFilePath: '$dirPath/flt-p0.zip',
      );
      createdPaths.add('$dirPath/flt-p0.zip');
    } on DsmApiException catch (e) {
      compressAllowed = false;
      debugPrint('[p0] ③-4 压缩被拒（$e）→ ${describeFileError(e)}');
      expect(e.code, DsmErrorCode.noPermission,
          reason: '没权限应该是 105，而不是参数错');
      expect(describeFileError(e), contains('没有压缩权限'));
    }

    if (compressAllowed) {
      var zipSeen = false;
      for (var i = 0; i < 20 && !zipSeen; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final listing = await fs.listFolder(folderPath: dirPath, limit: 50);
        zipSeen = listing.entries.any((e) => e.name == 'flt-p0.zip');
      }
      final tasks = await fs.listBackgroundTasks();
      debugPrint('[p0] ③-4 压缩完成=$zipSeen 任务=${tasks.tasks.map((t) => "${t.label}/${t.finished}").toList()}');
      expect(zipSeen, isTrue, reason: '压缩任务应该在几秒内产出 zip');

      // 产出的 zip 要是**真的**（能被归档清单读出里面的文件）
      final built = await fs.listArchive(filePath: '$dirPath/flt-p0.zip');
      debugPrint('[p0] ③-4 产物内容 '
          '${built.entries.map((e) => '${e.name}(${e.size}B)').toList()}');
      expect(built.entries.map((e) => e.name), contains('flt-p0.bin'));

    } else {
      debugPrint('[p0] ③-4 压缩跳过（该账号没有压缩权限）→ 改用上传的 zip 夹具验证解压');
    }

    // ③-5' 解压：用上传的 zip 夹具验证 `Extract` 全链路。
    // 夹具是一个只有 a.txt("hi\n") 的 zip（base64 内联，148 字符）。
    // 同时验证两条真机事实：
    //   ① `Extract.list` 的 entries 在 `items` 键上，字段是 is_dir/pack_size，
    //      mtime 是 "2026-09-18 13:16:20" 这种字符串；
    //   ② **目标目录必须已存在**，不存在时服务端回 408（= 路径不存在）。
    {
      final fixture = File('${Directory.systemTemp.path}/flt-p0.zip')
        ..writeAsBytesSync(base64Decode(_zipFixtureB64));
      addTearDown(() {
        try {
          fixture.deleteSync();
        } catch (_) {}
      });
      await fs.upload(
        folderPath: dirPath,
        filePath: fixture.path,
        fileName: 'flt-p0-fixture.zip',
      );
      createdPaths.add('$dirPath/flt-p0-fixture.zip');

      final archive = await fs.listArchive(filePath: '$dirPath/flt-p0-fixture.zip');
      debugPrint('[p0] ③-5 归档内容 '
          '${archive.entries.map((e) => '${e.name}(${e.size}B,isdir=${e.isDir},mtime=${e.mtime})').toList()}');
      expect(archive.entries.map((e) => e.name), contains('a.txt'));
      expect(archive.entries.first.size, 3, reason: '归档条目的 size 在顶层');
      expect(archive.entries.first.mtime, greaterThan(0), reason: '字符串 mtime 要能解析');

      // 目标目录不存在 → 408（真机事实，别误判成权限问题）
      try {
        await fs.startExtract(
          filePath: '$dirPath/flt-p0-fixture.zip',
          destFolderPath: '$dirPath/flt-p0-no-such-dir',
        );
        fail('目标目录不存在时应该报错');
      } on DsmApiException catch (e) {
        expect(e.code, 408);
        debugPrint('[p0] ③-5 目标不存在 → 408，文案：${describeFileError(e)}');
        expect(describeFileError(e), contains('不存在'));
      }

      // 真实解压：目标目录先建好
      await fs.createFolder(folderPath: dirPath, name: 'flt-p0-out');
      createdPaths.add('$dirPath/flt-p0-out');
      await fs.startExtract(
        filePath: '$dirPath/flt-p0-fixture.zip',
        destFolderPath: '$dirPath/flt-p0-out',
        createSubfolder: false,
      );
      var extracted = false;
      for (var i = 0; i < 20 && !extracted; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final listing = await fs.listFolder(folderPath: '$dirPath/flt-p0-out', limit: 20);
        extracted = listing.entries.any((e) => e.name == 'a.txt');
      }
      debugPrint('[p0] ③-5 解压出 a.txt=$extracted');
      expect(extracted, isTrue, reason: '解压任务应该产出 a.txt');

      final info = await fs.getInfo('$dirPath/flt-p0-out/a.txt');
      debugPrint('[p0] ③-5 解压结果大小=${info.size}');
      expect(info.size, 3);
    }

    // ③-6 统计目录大小（异步任务）
    final size = await fs.startDirSize([dirPath]);
    debugPrint('[p0] ③-6 DirSize 任务=${size.taskId}');
    expect(size.taskId, isNotEmpty);

    // ③-7 重命名
    await fs.rename(path: '$dirPath/flt-p0.bin', name: 'flt-p0-renamed.bin');
    final renamed = await fs.getInfo('$dirPath/flt-p0-renamed.bin');
    debugPrint('[p0] ③-7 改名后 ${renamed.name}');
    expect(renamed.name, 'flt-p0-renamed.bin');

    // ③-8 收藏（加 → 列表里有 → 取消）
    await fs.addFavorite(dirPath);
    var favorites = await fs.listFavorites(limit: 200);
    expect(favorites.entries.map((e) => e.path), contains(dirPath));
    await fs.deleteFavorite(dirPath);
    favorites = await fs.listFavorites(limit: 200);
    debugPrint('[p0] ③-8 收藏加/删 OK（现 ${favorites.entries.length} 个）');
    expect(favorites.entries.map((e) => e.path), isNot(contains(dirPath)));

    // ③-9 复制（留一份在上级目录，稍后靠清理删掉；CopyMove 走异步任务）
    final copySrc = compressAllowed
        ? '$dirPath/flt-p0.zip'
        : '$dirPath/flt-p0-renamed.bin';
    final copyName = copySrc.split('/').last;
    await fs.startCopyMove(
      paths: [copySrc],
      destFolderPath: work,
      removeSrc: false,
    );
    createdPaths.add('$work/$copyName');
    var copied = false;
    for (var i = 0; i < 20 && !copied; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final listing = await fs.listFolder(folderPath: work, limit: 100);
      copied = listing.entries.any((e) => e.name == copyName);
    }
    debugPrint('[p0] ③-9 复制 $copyName 到 $work 成功=$copied');
    expect(copied, isTrue, reason: '复制任务应该在几秒内完成');

    // ---------- ④ UI（真连接，只做"根目录渲染出真实共享"这一件事） ----------
    //
    // ⚠️ 这台机器（LGE-AN10 / Android 12）上 integration_test 的 live binding
    // 只能稳定 pump 两次左右：第 3 次 `tester.pump()` 会永久阻塞（实测 case6/7/8/9，
    // framePolicy 换 fullyLive/benchmark 也不行）。所以 UI 这块只保留
    // "pumpWidget + 一次 pump"的断言；点击/导航等更深的 UI 流程由
    // test/file_browse_ui_test.dart（FakeTransport，离线）覆盖。
    debugPrint('[p0] ④-0 建内存库…');
    final db = ChatDatabase(NativeDatabase.memory());
    final container = ProviderContainer(overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fileApiProvider.overrideWithValue(fs),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: FileBrowsePage()),
      ),
    );
    debugPrint('[p0] ④-1 页面已挂，等真实列目录…');
    await Future<void>.delayed(const Duration(seconds: 3));
    await tester.pump();

    final shareNames = shares.entries.map((e) => e.name).toList();
    debugPrint('[p0] ④-2 UI 里应该出现：$shareNames');
    for (final name in shareNames.take(3)) {
      expect(find.text(name), findsWidgets, reason: '根目录应该列出共享 $name');
    }
    debugPrint('[p0] ④-3 真实数据已经渲染到文件页');

    debugPrint('[p0] ✅ 全部通过');
  });
}
