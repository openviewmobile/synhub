// **可写的内存笔记本 / 笔记**：让 Mock 也能"记住"笔记模块的写动词。
//
// 为什么需要它（第 324 轮，macOS 写侧第三档）：
//   r319/r320–r323 已经把**文件站**与**下载站**的写动词接到可写内存上；
//   笔记模块（`SYNO.NoteStation.*`）在 Mock Server 上**一条夹具都没有**
//   ⇒ `--fs-demo --download-demo` 的服务器上，笔记页只能走
//   "未注册夹具 ⇒ `{'success':true,'data':{}}`"（§2.0.38 的契约），
//   于是「新建/编辑笔记」成功没有在**跨进程**意义上无法判定。
//
// 做法：把 `Notebook.list|create` 与 `Note.list|get|create|set|delete`
//   接到**同一个内存库**上，于是
//   「种子笔记出现在列表 → 改标题保存 → 另一个 HTTP 客户端读回新标题」
//   是一条真链路（判据取 `Note/list` 的回读值，不取响应体）。
//
// ★ 字段名逐字对齐官方 `NoteVo` / `NotebookVo`（`lib/src/data/dto/note_dto.dart`
//   的 `fromJson` 就是它们的消费方）：
//   `object_id` / `title` / `parent_id` / `content` / `brief` / `ctime` / `mtime`
//   / `ver` / `encrypt`；列表根键是 **`notes`** / **`notebooks`**（`total` 记账在顶层）。
// ★ ★★ `Note/set` 的回包形状与 `list`/`get` **不一样**（官方 `NoteVoV2`）：
//   `data: {data: [noteVo…], errors: [{code, object_id}…]}` —— 一个请求可以
//   同时成功几条、失败几条。这里的夹具必须回这个形状，否则客户端 `_unwrapSetResponse`
//   会把一次成功的保存读成 `null`（"保存了但界面以为没保存"）。
// ★ 一切都在内存里，进程退出即消失；**不碰**真 NAS、不碰磁盘。
import 'mock_ds_demo.dart';
import 'mock_dsm_core.dart';

/// 内存库里的一个笔记本。
class MockNoteBook {
  MockNoteBook({
    required this.id,
    required this.title,
    this.preset = false,
    this.archive = false,
    int? ctime,
  }) : ctime = ctime ?? _now,
       mtime = ctime ?? _now,
       ver = '1';

  final String id;
  String title;
  final bool preset;
  final bool archive;
  final int ctime;
  int mtime;
  String ver;

  static int get _now =>
      DateTime.now().millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;
}

/// 内存库里的一个笔记。
class MockNote {
  MockNote({
    required this.id,
    required this.title,
    required this.parentId,
    this.content = '',
    this.brief = '',
    int? ctime,
  }) : ctime = ctime ?? MockNoteBook._now,
       mtime = ctime ?? MockNoteBook._now,
       ver = '1';

  final String id;
  String title;
  String parentId;
  String content;
  String brief;
  final int ctime;
  int mtime;

  /// 乐观锁版本号（`Note/set` 要回传；每次成功保存 **+1**）。
  String ver;
}

/// 一个极小的内存 NoteStation。
class MockNoteStation {
  MockNoteStation._(this._notebooks, this._notes, this._seq);

  /// 默认**只种子一个"我的记事本"**（官方预设笔记本：`preset=true`、`title` 空）。
  ///
  /// 为什么要种子：笔记页新建笔记要求"有笔记本可选"
  /// （没选中笔记本直接保存会提示"先选笔记本"）—— 没有种子笔记本，
  /// 集成测试里"新建笔记"这条路**根本走不到**。
  factory MockNoteStation.seeded() {
    final nb = MockNoteBook(id: 'nb_1', title: '', preset: true);
    final notes = <MockNote>[
      MockNote(id: 'note_1', title: 'mock seeded note', parentId: nb.id),
    ];
    return MockNoteStation._(<MockNoteBook>[nb], notes, 1);
  }

  /// 空库（只留一个笔记本）——"列表里没有某条"类判据从这里起步。
  factory MockNoteStation.empty() {
    final nb = MockNoteBook(id: 'nb_1', title: '', preset: true);
    return MockNoteStation._(<MockNoteBook>[nb], <MockNote>[], 1);
  }

  final List<MockNoteBook> _notebooks;
  final List<MockNote> _notes;
  int _seq;

  List<MockNoteBook> get notebooks => List.unmodifiable(_notebooks);
  List<MockNote> get notes => List.unmodifiable(_notes);

  MockNoteBook? notebookById(String id) {
    for (final n in _notebooks) {
      if (n.id == id) return n;
    }
    return null;
  }

  MockNote? noteById(String id) {
    for (final n in _notes) {
      if (n.id == id) return n;
    }
    return null;
  }

  MockNoteBook addNotebook(String title) {
    _seq++;
    final nb = MockNoteBook(id: 'nb_$_seq', title: title);
    _notebooks.add(nb);
    return nb;
  }

  MockNote addNote({
    required String title,
    required String parentId,
    String content = '',
    String brief = '',
  }) {
    _seq++;
    final n = MockNote(
      id: 'note_$_seq',
      title: title,
      parentId: parentId,
      content: content,
      brief: brief,
    );
    _notes.add(n);
    return n;
  }

  /// `Note/set` 的成功分支：改字段 + **版本号 +1**。
  ///
  /// ★ 只改**真的传了值**的字段（`title: ''` 是合法值 —— 官方允许空标题，
  ///   所以这里不能拿"空串"当"没传"，要看**参数在不在**）。
  void applySet(
    MockNote n, {
    String? title,
    String? content,
    String? parentId,
    int? mtime,
  }) {
    if (title != null) n.title = title;
    if (content != null) n.content = content;
    if (parentId != null && parentId.isNotEmpty) n.parentId = parentId;
    n.mtime = mtime ?? MockNoteBook._now;
    n.ver = '${(int.tryParse(n.ver) ?? 1) + 1}';
  }

  bool removeNote(String id) {
    final before = _notes.length;
    _notes.removeWhere((n) => n.id == id);
    return _notes.length != before;
  }
}

extension MockNoteStationDemo on MockDsmBackend {
  /// 装上"可写内存笔记库"的接口。返回库的引用（用例可直接查状态）。
  MockNoteStation installNoteDemo({MockNoteStation? ns}) {
    final db = ns ?? MockNoteStation.seeded();

    /// 列表项**不带 `content`**（官方 `Note/list` 就不带正文；
    /// 客户端 `NoteDto.hasContent` 正是按"响应里有没有 `content` 键"判的）。
    Map<String, dynamic> noteBriefJson(MockNote n) => {
      'object_id': n.id,
      'title': n.title,
      'parent_id': n.parentId,
      'brief': n.brief,
      'ctime': n.ctime,
      'mtime': n.mtime,
      'ver': n.ver,
      'encrypt': false,
      'tag': <String>[],
      'recycle': false,
    };

    Map<String, dynamic> noteFullJson(MockNote n) => {
      ...noteBriefJson(n),
      'content': n.content,
    };

    Map<String, dynamic> notebookJson(MockNoteBook b) => {
      'object_id': b.id,
      'title': b.title,
      'preset': b.preset,
      'archive': b.archive,
      'ctime': b.ctime,
      'mtime': b.mtime,
      'ver': b.ver,
    };

    fixture('SYNO.NoteStation.Notebook', 'list', (p) {
      // `filter={"archive":false}`（v2）——把归档的滤掉
      final filter = '${p['filter'] ?? ''}';
      final includeArchived = filter.contains('"archive":true');
      final list = [
        for (final b in db.notebooks)
          if (includeArchived || !b.archive) b,
      ];
      return {
        'success': true,
        'data': {
          'notebooks': list.map(notebookJson).toList(),
          'total': list.length,
        },
      };
    });

    fixture('SYNO.NoteStation.Notebook', 'create', (p) {
      final title = unquoteJson('${p['title'] ?? ''}');
      final nb = db.addNotebook(title);
      return {
        'success': true,
        'data': {'object_id': nb.id},
      };
    });

    fixture('SYNO.NoteStation.Note', 'list', (p) {
      final all = [...db.notes];
      // 官方按 `sort_by` / `sort_direction` 排（默认 mtime 降序）；
      // 这里只需要"顺序稳定"，但**必须真的认这个参数**，否则
      // "排序参数发对了没有"在跨进程判据里看不出来。
      final by = '${p['sort_by'] ?? 'mtime'}';
      final desc = '${p['sort_direction'] ?? 'desc'}' != 'asc';
      all.sort((a, b) {
        final va = by == 'ctime' ? a.ctime : a.mtime;
        final vb = by == 'ctime' ? b.ctime : b.mtime;
        return desc ? vb.compareTo(va) : va.compareTo(vb);
      });
      final offset = int.tryParse('${p['offset'] ?? 0}') ?? 0;
      final limit = int.tryParse('${p['limit'] ?? 0}') ?? 0;
      final total = all.length;
      final page = limit > 0 && offset + limit < total
          ? all.sublist(offset, offset + limit)
          : all.sublist(offset.clamp(0, total));
      return {
        'success': true,
        'data': {
          'notes': page.map(noteBriefJson).toList(),
          'total': total,
          'offset': offset,
        },
      };
    });

    fixture('SYNO.NoteStation.Note', 'get', (p) {
      final id = unquoteJson('${p['object_id'] ?? ''}');
      final n = db.noteById(id);
      if (n == null) {
        return {
          'success': false,
          'error': {'code': 117},
        };
      }
      return {
        'success': true,
        'data': noteFullJson(n),
      };
    });

    // ★ 写动词本体。参数名逐字对齐客户端 `createNote`：
    //   `title` / `parent_id` / `content` / `brief` / `ctime` / `encrypt` / `commit_msg`
    //   —— 全部是 **JSON 串**（`js(...)`），所以这里要 `unquoteJson` 再读。
    fixture('SYNO.NoteStation.Note', 'create', (p) {
      final title = unquoteJson('${p['title'] ?? ''}');
      final parentId = unquoteJson('${p['parent_id'] ?? ''}');
      final content = unquoteJson('${p['content'] ?? ''}');
      final brief = unquoteJson('${p['brief'] ?? ''}');
      // 缺必填 = 114（不许回"创建成功但什么都没有"）
      if (parentId.isEmpty || db.notebookById(parentId) == null) {
        return {
          'success': false,
          'error': {'code': 114},
        };
      }
      final n = db.addNote(
        title: title,
        parentId: parentId,
        content: content,
        brief: brief,
      );
      return {
        'success': true,
        'data': {'object_id': n.id, 'ver': n.ver},
      };
    });

    fixture('SYNO.NoteStation.Note', 'set', (p) {
      final id = unquoteJson('${p['object_id'] ?? ''}');
      // ★ `title`/`content` 用 **containsKey** 判"参数在不在" ——
      //   `title: ""` 是合法的（官方允许空标题），空串不能当"没传"。
      final hasTitle = p.containsKey('title');
      final hasContent = p.containsKey('content');
      final title = hasTitle ? unquoteJson('${p['title']}') : null;
      final content = hasContent ? unquoteJson('${p['content']}') : null;
      final mtime = int.tryParse(unquoteJson('${p['mtime'] ?? ''}'));
      final n = db.noteById(id);
      if (n == null) {
        // 官方 `Note/set` 的回包形状：**错误也走同一个信封**
        return {
          'success': true,
          'data': {
            'data': <dynamic>[],
            'errors': [
              {'code': 117, 'object_id': id},
            ],
          },
        };
      }
      db.applySet(n, title: title, content: content, mtime: mtime);
      return {
        'success': true,
        'data': {
          'data': [noteFullJson(n)],
          'errors': <dynamic>[],
        },
      };
    });

    fixture('SYNO.NoteStation.Note', 'delete', (p) {
      final id = unquoteJson('${p['object_id'] ?? ''}');
      final ok = db.removeNote(id);
      return {
        'success': true,
        'data': {'count': ok ? 1 : 0},
      };
    });

    return db;
  }
}

// ★ `stringList` / `unquoteJson` 复用 `mock_ds_demo.dart` 里的**同一个**助手
//   （两处各写一份迟早语义漂移；同一个 library 里也放不下两个同名函数）。
