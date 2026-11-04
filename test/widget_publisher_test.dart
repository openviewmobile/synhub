// 小组件**采集层**的单测：DTO → 条目 的纯适配 + 推送器在"离线/坏数据"下的行为。
//
// 全部离线：不连 NAS、不碰平台通道（用假桥）、缩略图目录用临时目录注入，
// 不调用 path_provider 插件。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/features/widgets/widget_bridge.dart';
import 'package:synhub/src/features/widgets/widget_snapshot.dart';
import 'package:synhub/src/features/widgets/widget_snapshot_publisher.dart';

/// 记下收到什么的假桥（不碰 MethodChannel）。
class _FakeBridge implements WidgetBridge {
  final List<String> pushed = [];

  @override
  Future<bool> pushSnapshot(String snapshotJson) async {
    pushed.add(snapshotJson);
    return true;
  }

  @override
  Future<bool> requestRefresh() async => true;

  @override
  Future<String?> takePendingTarget() async => null;

  @override
  Stream<void> get onAction => const Stream<void>.empty();
}

/// 假的"取缩略图"：记调用次数，按 itemId 决定成功/失败。
class _FakeThumbs {
  _FakeThumbs({this.failFor = const {}});

  final Set<String> failFor;
  final List<String> asked = [];

  Future<Uint8List?> fetch(FotoItemDto item) async {
    asked.add(item.id);
    if (failFor.contains(item.id)) throw StateError('boom');
    return Uint8List.fromList(List<int>.filled(16, 7));
  }
}

FotoItemDto _photo(String id, {int time = 0, String name = 'x.jpg'}) =>
    FotoItemDto(id: id, filename: name, time: time);

NoteDto _note(
  String id, {
  int mtime = 0,
  String title = 't',
  bool enc = false,
}) => NoteDto(objectId: id, title: title, mtime: mtime, encrypt: enc);

TodoDto _todo(
  String id, {
  String title = 'x',
  String noteId = '',
  int due = 0,
  bool done = false,
}) => TodoDto(
  objectId: id,
  title: title,
  noteId: noteId,
  dueDate: due,
  done: done,
);

void main() {
  group('DTO → 小组件条目的纯适配', () {
    test('照片：取文件名与拍摄时间，视频标记带上', () {
      final e = widgetPhotoEntryOf(
        FotoItemDto(
          id: '42',
          filename: 'IMG_0042.JPG',
          time: 1700000000,
          type: 'video',
        ),
      );
      expect(e.id, '42');
      expect(e.name, 'IMG_0042.JPG');
      expect(e.takenAt, 1700000000);
      expect(e.isVideo, isTrue);
      // 缩略图路径由**副作用层**后补，纯适配阶段必须是 null
      expect(e.thumbPath, isNull);
    });

    test('笔记：只带标题，加密标记带上，正文绝不外带', () {
      final e = widgetNoteEntryOf(
        _note('n1', title: '私密', mtime: 9, enc: true),
      );
      expect(e.id, 'n1');
      expect(e.title, '私密');
      expect(e.encrypted, isTrue);
      // ★ 第 109 轮：为对齐官方 `NotebookAppWidgetProvider`（按本过滤）
      //   新增了 `notebookId`/`notebookName` —— 键集合随之扩大，
      //   但**仍然不含任何正文字段**（这条不变式才是本用例要守的东西）。
      expect(e.toJson().keys.toSet(), {
        'id',
        'title',
        'mtime',
        'encrypted',
        'notebookId',
        'notebookName',
      });
      for (final banned in ['content', 'body', 'html', 'plain', 'text']) {
        expect(
          e.toJson().containsKey(banned),
          isFalse,
          reason: '小组件快照绝不能带正文字段 $banned',
        );
      }
    });

    test('待办：带上所属笔记 id、截止时间与完成态', () {
      final e = widgetTodoEntryOf(
        _todo('t1', title: '买菜', noteId: 'n1', due: 1700000000),
      );
      expect(e.noteId, 'n1');
      expect(e.due, 1700000000);
      expect(e.hasDue, isTrue);
      expect(e.done, isFalse);
    });

    test('空标题有兜底，不显示空行', () {
      expect(
        widgetNoteEntryOf(_note('n', title: '   ')).displayTitle,
        isNotEmpty,
      );
      expect(widgetTodoEntryOf(_todo('t', title: '')).displayTitle, isNotEmpty);
      expect(widgetPhotoEntryOf(_photo('p', name: '')).displayName, isNotEmpty);
    });
  });

  group('WidgetSnapshotPublisher（离线推送）', () {
    test('未登录 + 空数据：仍然推出一份可解析的快照（占位而不是空白）', () async {
      final bridge = _FakeBridge();
      final ok = await WidgetSnapshotPublisher(
        bridge: bridge,
      ).publish(loggedIn: false, connected: false);
      expect(ok, isTrue);
      expect(bridge.pushed, hasLength(1));
      final snap = decodeWidgetSnapshot(bridge.pushed.single);
      expect(snap, isNotNull);
      expect(snap!.loggedIn, isFalse);
      expect(widgetPhotoPlaceholder(snap), WidgetPlaceholder.notLoggedIn);
      expect(widgetNotePlaceholder(snap), WidgetPlaceholder.notLoggedIn);
    });

    test('已登录未连接：推"未连接"占位，且**不**尝试下载缩略图', () async {
      final bridge = _FakeBridge();
      final thumbs = _FakeThumbs();
      await WidgetSnapshotPublisher(bridge: bridge).publish(
        loggedIn: true,
        connected: false,
        photos: [_photo('p1'), _photo('p2')],
        photoBytes: thumbs.fetch,
      );
      expect(thumbs.asked, isEmpty, reason: '未连接时不该发起必然失败的请求');
      final snap = decodeWidgetSnapshot(bridge.pushed.single)!;
      expect(snap.photos, hasLength(2));
      expect(widgetPhotoPlaceholder(snap), WidgetPlaceholder.notConnected);
    });

    test('已连接：只推最近 N 张（不把整个时间轴塞进快照）', () async {
      final bridge = _FakeBridge();
      await WidgetSnapshotPublisher(bridge: bridge).publish(
        loggedIn: true,
        connected: true,
        photos: [for (var i = 0; i < 50; i++) _photo('p$i', time: i)],
      );
      final snap = decodeWidgetSnapshot(bridge.pushed.single)!;
      expect(snap.photos, hasLength(kWidgetPhotoLimit));
      expect(snap.photos.map((e) => e.id).toList(), [
        'p49',
        'p48',
        'p47',
        'p46',
      ]);
    });

    test('缩略图成功 → thumbPath 指向真实存在的本机文件', () async {
      final bridge = _FakeBridge();
      final tmp = await Directory.systemTemp.createTemp('widget_thumbs_test');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      final thumbs = _FakeThumbs();
      await WidgetSnapshotPublisher(
        bridge: bridge,
        thumbs: WidgetThumbStore(baseDirectory: () async => tmp),
      ).publish(
        loggedIn: true,
        connected: true,
        photos: [_photo('p1')],
        photoBytes: thumbs.fetch,
      );
      final snap = decodeWidgetSnapshot(bridge.pushed.single)!;
      final path = snap.photos.single.thumbPath;
      expect(path, isNotNull);
      expect(await File(path!).exists(), isTrue);
      expect(await File(path).length(), 16);
    });

    test('单张缩略图取失败 → 该张 thumbPath 为 null，其余照常（不崩）', () async {
      final bridge = _FakeBridge();
      final tmp = await Directory.systemTemp.createTemp('widget_thumbs_fail');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      final thumbs = _FakeThumbs(failFor: {'p1'});
      await WidgetSnapshotPublisher(
        bridge: bridge,
        thumbs: WidgetThumbStore(baseDirectory: () async => tmp),
      ).publish(
        loggedIn: true,
        connected: true,
        photos: [_photo('p1', time: 2), _photo('p2', time: 1)],
        photoBytes: thumbs.fetch,
      );
      final snap = decodeWidgetSnapshot(bridge.pushed.single)!;
      final byId = {for (final p in snap.photos) p.id: p};
      expect(byId['p1']!.thumbPath, isNull);
      expect(byId['p2']!.thumbPath, isNotNull);
    });

    test('未完成待办才进快照，已完成不进', () async {
      final bridge = _FakeBridge();
      await WidgetSnapshotPublisher(bridge: bridge).publish(
        loggedIn: true,
        connected: true,
        todos: [_todo('t1'), _todo('t2', done: true)],
      );
      final snap = decodeWidgetSnapshot(bridge.pushed.single)!;
      expect(snap.todos.map((e) => e.id).toList(), ['t1']);
    });

    test('平台不收（假桥返回 false）→ publish 返回 false，不抛', () async {
      final bridge = _RejectingBridge();
      final ok = await WidgetSnapshotPublisher(
        bridge: bridge,
      ).publish(loggedIn: true, connected: true);
      expect(ok, isFalse);
    });

    test('空列表 / 空 id 不崩', () async {
      final bridge = _FakeBridge();
      await WidgetSnapshotPublisher(bridge: bridge).publish(
        loggedIn: true,
        connected: true,
        photos: [_photo(''), _photo('  ')],
        notes: [_note('')],
        todos: [_todo('')],
      );
      final snap = decodeWidgetSnapshot(bridge.pushed.single)!;
      expect(snap.photos, isEmpty);
      expect(snap.notes, isEmpty);
      expect(snap.todos, isEmpty);
    });
  });
}

/// 平台明确拒收的假桥。
class _RejectingBridge extends _FakeBridge {
  @override
  Future<bool> pushSnapshot(String snapshotJson) async => false;
}
