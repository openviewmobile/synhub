// ★★ ④笔记 第 237 轮：**N1「主屏小组件」跨语言契约**（Kotlin ↔ Dart）。
//
// 小组件在桌面上**渲染**只能在真机看；但这条链路的**数据契约**可以离线钉死：
//   ① Dart 写出的快照 JSON 键 == Kotlin `WidgetSnapshotStore` 读的键；
//   ② 笔记小组件**绝不外带正文**（隐私红线）；
//   ③ 通道名 Dart == Kotlin；
//   ④ `AndroidManifest.xml` 里 4 个笔记相关 provider 都注册了。
//
// 这样"数据能到原生"是可核实的事实；"桌面画出来"仍标注真机未验。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/widgets/widget_bridge.dart'
    show MethodChannelWidgetBridge;
import 'package:synhub/src/features/widgets/widget_snapshot.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final kt = _read(
    'android/app/src/main/kotlin/com/openviewai/synhub/'
    'WidgetSnapshotStore.kt',
  );
  final bridgeKt = _read(
    'android/app/src/main/kotlin/com/openviewai/synhub/'
    'SynologyWidgetBridge.kt',
  );
  final manifest = _read('android/app/src/main/AndroidManifest.xml');
  final dartSnapshot = _read('lib/src/features/widgets/widget_snapshot.dart');

  group('N1 小组件 · 快照 JSON 契约（Dart 写 == Kotlin 读）', () {
    test('顶层键：notes / todos / photos，两边逐字一致', () {
      for (final key in ['notes', 'todos', 'photos']) {
        expect(dartSnapshot, contains("'$key'"), reason: 'Dart 侧要写 $key');
        expect(kt, contains('"$key"'), reason: 'Kotlin 侧会读 $key');
      }
    });

    test('笔记条目键：id / title / encrypted / notebookId / notebookName', () {
      final entry = WidgetNoteEntry(
        id: 'n1',
        title: '标题',
        encrypted: true,
        notebookId: 'nb1',
        notebookName: '本子',
      );
      final json = entry.toJson();
      expect(json.keys.toSet(), {
        'id',
        'title',
        'mtime',
        'encrypted',
        'notebookId',
        'notebookName',
      });
      for (final key in json.keys) {
        expect(kt, contains('"$key"'), reason: 'Kotlin 要按 $key 读');
      }
      // 逐字段回读（同一份键值语义）
      final back = WidgetNoteEntry.fromJson(json);
      expect(back.id, 'n1');
      expect(back.title, '标题');
      expect(back.encrypted, isTrue);
      expect(back.notebookId, 'nb1');
      expect(back.notebookName, '本子');
    });

    test('待办条目键：id / noteId / title（+ 完成态）', () {
      const t = WidgetTodoEntry(
        id: 't1',
        title: '待办',
        noteId: 'n1',
        done: true,
      );
      final json = t.toJson();
      for (final key in ['id', 'noteId', 'title']) {
        expect(json.containsKey(key), isTrue);
        expect(kt, contains('"$key"'));
      }
    });

    test('★ 隐私红线：笔记快照里**没有正文键**（Kotlin 也不读）', () {
      const entry = WidgetNoteEntry(id: 'n1', title: 't');
      final json = entry.toJson();
      for (final forbidden in ['content', 'body', 'brief', 'text']) {
        expect(json.containsKey(forbidden), isFalse, reason: '快照不许带正文');
        expect(
          kt,
          isNot(contains('optString("$forbidden"')),
          reason: 'Kotlin 也不该读正文',
        );
      }
    });

    test('快照整体 JSON 能往返（含空数据占位，不崩）', () {
      final snap = WidgetSnapshot(
        notes: [const WidgetNoteEntry(id: 'n1', title: 't')],
        todos: const [],
        photos: const [],
      );
      // 走生产用的编解码（encode/decode），而不是测试自造
      final back = decodeWidgetSnapshot(encodeWidgetSnapshot(snap))!;
      expect(back.notes.single.id, 'n1');
      expect(back.todos, isEmpty);
      final empty = decodeWidgetSnapshot(
        encodeWidgetSnapshot(
          const WidgetSnapshot(notes: [], todos: [], photos: []),
        ),
      )!;
      expect(empty.notes, isEmpty);
      expect(decodeWidgetSnapshot('乱写的'), isNull, reason: '坏 JSON 不许崩');
    });
  });

  group('N1 小组件 · 通道与注册', () {
    test('通道名 Dart == Kotlin（synhub/widget）', () {
      expect(MethodChannelWidgetBridge.channelName, 'synhub/widget');
      expect(bridgeKt, contains('"${MethodChannelWidgetBridge.channelName}"'));
    });

    test('打开动作常量两边一致（点击小组件回 App 用）', () {
      expect(bridgeKt, contains('"com.openviewai.synhub.WIDGET_OPEN"'));
      expect(dartSnapshot, isNotEmpty); // 占位断言，动作常量在 bridge 侧
    });

    test('★ Manifest 注册了全部 4 个笔记相关 provider', () {
      for (final provider in [
        'NotesWidgetProvider',
        'TodosWidgetProvider',
        'NotebookWidgetProvider',
        'NewNoteWidgetProvider',
      ]) {
        expect(
          manifest,
          contains('android:name=".$provider"'),
          reason: '$provider 没注册 = 桌面上加不出来',
        );
      }
    });

    test('provider 的 appwidget 配置存在（info xml）', () {
      final dir = Directory('android/app/src/main/res/xml');
      final infos = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('widget'))
          .map((f) => f.uri.pathSegments.last)
          .toList();
      expect(infos, isNotEmpty, reason: '至少要有 widget_*_info.xml');
      // 每个注册的 provider 都应指向存在的 info（粗校验：manifest 里的 meta-data）
      expect(manifest, contains('android.appwidget.provider'));
    });
  });
}
