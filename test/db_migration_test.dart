// 本地库的版本迁移（`ChatDatabase.migration`）。
//
// 起因：v6 的 `broken_users` 当初只改了 `schemaVersion` 没写 `onUpgrade`，
// 老库升上来会 "no such column" —— 这类 bug 只有真跑一次升级才看得见，
// 所以这里用**临时文件库**手工造一个 v5 的老库，再用当前版本打开。
//
// v8：新增文件条目表（文件模块的目录缓存）也是同理 —— 老库必须能升上来。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/local/book_store.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/local/file_store.dart';

Future<bool> _hasColumn(ChatDatabase db, String table, String column) async {
  final rows = await db.customSelect("PRAGMA table_info('$table')").get();
  return rows.any((r) => r.read<String>('name') == column);
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chat-db-migration');
    file = File('${dir.path}/chat.sqlite');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('v5 → v7：补上 broken_users 与 hashtags 两列，且数据能写能读', () async {
    // 1) 先建一个当前版本的库，再把 v6/v7 新增的两列删掉，冒充 v5
    final fresh = ChatDatabase(NativeDatabase(file));
    expect(await _hasColumn(fresh, 'channel_rows', 'broken_users'), isTrue);
    expect(await _hasColumn(fresh, 'channel_rows', 'hashtags'), isTrue);
    await fresh.customStatement(
      'ALTER TABLE channel_rows DROP COLUMN broken_users',
    );
    await fresh.customStatement(
      'ALTER TABLE channel_rows DROP COLUMN hashtags',
    );
    await fresh.customStatement('PRAGMA user_version = 5');
    await fresh.close();

    // 2) 用当前版本打开：Drift 看到 user_version=5 就会跑 onUpgrade(5→7)
    final db = ChatDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(
      await _hasColumn(db, 'channel_rows', 'broken_users'),
      isTrue,
      reason: 'v6 迁移：broken_users',
    );
    expect(
      await _hasColumn(db, 'channel_rows', 'hashtags'),
      isTrue,
      reason: 'v7 迁移：hashtags',
    );

    // 3) 新列真的能写能读（光有列名不够）
    final store = ChatStore(db);
    await store.upsertChannels([
      ChannelDto.fromJson({
        'channel_id': 9,
        'name': '老库升上来的频道',
        'type': 'private',
        'members': [14],
        'broken_users': [6, 7],
      }),
    ]);
    await store.updateChannelHashtags(9, ['周报', 'report']);
    final c = (await store.allChannels()).firstWhere((c) => c.channelId == 9);
    expect(c.brokenUsers, [6, 7]);
    expect(c.hashtags, ['周报', 'report']);
  });

  test('v7 → v8：新增 file_entry_rows 表，且缓存能写能读', () async {
    // 造一个"自称 v7"的库：把文件条目表删掉
    final fresh = ChatDatabase(NativeDatabase(file));
    await fresh.customStatement('DROP TABLE file_entry_rows');
    await fresh.customStatement('PRAGMA user_version = 7');
    await fresh.close();

    final db = ChatDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final tables = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
        .get();
    expect(
      tables.map((r) => r.read<String>('name')).toList(),
      contains('file_entry_rows'),
      reason: 'v8 迁移：文件条目表',
    );

    // 新表真的能写能读（光有表名不够）
    final store = FileStore(db);
    await store.replaceFolder('/home', [
      const FileEntryDto(
        name: 'Photos',
        path: '/home/Photos',
        isDir: true,
        canWrite: true,
      ),
      const FileEntryDto(name: 'a.txt', path: '/home/a.txt', size: 12),
    ]);
    expect((await store.folder('/home')).map((e) => e.name), [
      'Photos',
      'a.txt',
    ]);
    expect((await store.folder('/home')).first.canWrite, isTrue);
  });

  test('v10 → v11：阅读进度补上 source_url 列，且能写能读', () async {
    // 造一个"自称 v10"的库：把工作台「继续阅读」要用的定位串列删掉
    final fresh = ChatDatabase(NativeDatabase(file));
    expect(await _hasColumn(fresh, 'book_progress_rows', 'source_url'), isTrue);
    await fresh.customStatement(
      'ALTER TABLE book_progress_rows DROP COLUMN source_url',
    );
    // 真正的 v10 库里 `file_entry_rows` 也还没有 v13 的 `worm_state`
    // （那列是 v13 才加的），所以伪造时一并删掉，否则 onUpgrade 补列会撞
    // "duplicate column name" —— 这是**伪造老库要忠实**，不是放宽断言。
    await fresh.customStatement(
      'ALTER TABLE file_entry_rows DROP COLUMN worm_state',
    );
    await fresh.customStatement('PRAGMA user_version = 10');
    await fresh.close();

    final db = ChatDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(
      await _hasColumn(db, 'book_progress_rows', 'source_url'),
      isTrue,
      reason: 'v11 迁移：阅读进度的重开定位串',
    );

    // 新列真的能写能读（光有列名不够）
    final store = BookStore(db);
    await store.saveProgress(
      bookKey: 'drive:LINK',
      title: '驱动书',
      format: 'EPUB',
      chapter: 1,
      scroll: 0.1,
      chapterCount: 4,
      sourceUrl: 'https://nas/d/f/LINK',
    );
    expect(
      (await store.progressOf('drive:LINK'))!.sourceUrl,
      'https://nas/d/f/LINK',
    );
  });

  test('v12 → v13：文件条目补上 worm_state 列，老数据保留且未知态不拦', () async {
    // 造一个"自称 v12"的库：文件条目表**先有数据**，再把 v13 才加的列删掉。
    // 这样既能验证迁移把列加回来，也能验证老缓存行一行没丢。
    final fresh = ChatDatabase(NativeDatabase(file));
    expect(await _hasColumn(fresh, 'file_entry_rows', 'worm_state'), isTrue);
    await FileStore(fresh).replaceFolder('/home', [
      const FileEntryDto(name: 'old.txt', path: '/home/old.txt', size: 7),
    ]);
    await fresh.customStatement(
      'ALTER TABLE file_entry_rows DROP COLUMN worm_state',
    );
    await fresh.customStatement('PRAGMA user_version = 12');
    await fresh.close();

    final db = ChatDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(
      await _hasColumn(db, 'file_entry_rows', 'worm_state'),
      isTrue,
      reason: 'v13 迁移：WORM 状态列',
    );

    // 老数据保留，且新列取默认空串 → DTO 侧是 null = 未知（fail-open 不拦）
    final old = await FileStore(db).entry('/home/old.txt');
    expect(old, isNotNull, reason: '老缓存行不能因为加列就丢');
    expect(old!.size, 7);
    expect(old.wormState, isNull, reason: '老库那一列是空串 = 未知');
    expect(old.wormLocked, isFalse, reason: '未知不拦（保持 C5 fail-open）');
  });

  test('v3 → v7：bot_props / key_value 等 v4 以后新增的补上', () async {
    // 造一个"自称 v3"的库：把 v4 之后新增的东西都删掉。
    // 注意 `props` 是 v3 就有的，v3 的老库本来就该有它，不能删（删了就前后不一致，
    // 迁移也不会补——`from < 3` 在 from=3 时是 false）。
    final fresh = ChatDatabase(NativeDatabase(file));
    expect(await _hasColumn(fresh, 'post_rows', 'props'), isTrue);
    await fresh.customStatement('DROP TABLE key_value_rows');
    await fresh.customStatement('DROP TABLE file_entry_rows');
    await fresh.customStatement('ALTER TABLE user_rows DROP COLUMN bot_props');
    await fresh.customStatement(
      'ALTER TABLE channel_rows DROP COLUMN broken_users',
    );
    await fresh.customStatement(
      'ALTER TABLE channel_rows DROP COLUMN hashtags',
    );
    await fresh.customStatement('PRAGMA user_version = 3');
    await fresh.close();

    final db = ChatDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await _hasColumn(db, 'user_rows', 'bot_props'), isTrue);
    expect(await _hasColumn(db, 'channel_rows', 'broken_users'), isTrue);
    expect(await _hasColumn(db, 'channel_rows', 'hashtags'), isTrue);
    final tables = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
        .get();
    expect(
      tables.map((r) => r.read<String>('name')).toList(),
      contains('key_value_rows'),
    );
    expect(
      tables.map((r) => r.read<String>('name')).toList(),
      contains('file_entry_rows'),
    );
  });
}
