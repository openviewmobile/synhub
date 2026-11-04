// **可写的内存文件系统**：让 Mock 也能"记住"写动词的结果。
//
// 为什么需要它（第 319 轮，macOS 写侧验收）：
//   `MockDsmBackend` 的契约是「没注册夹具 ⇒ `success:true, data:{}`」（§2.0.38）。
//   这对只读走查够用，但**写动词走查**会永远看到旧列表 ——
//   "新建文件夹 → 列表里没有它"在这种 Mock 上**既不能判成功也不能判失败**。
//   于是 macOS/Linux/iOS 的写侧只能停在"请求发出去了"，而这正是
//   §2.0.29「改了 ≠ 改对了」最容易骗过自己的地方。
//
// 做法：把 `List.list` / `CreateFolder.create` / `Rename.rename` / `Delete.delete`
// 四条接到**同一个内存树**上，于是界面上的"新建 → 出现在列表 → 改名 → 消失"
// 是一条真链路（判据 = 服务端状态，不是界面自己的乐观更新）。
//
// ⚠️ 只在 **HTTP Server**（`mock_dsm_server.dart`，`--fs-demo`）里安装；
//    `mock_dsm_core.dart` 的离线用例**不受影响**（它们各自注册自己的夹具）。
// ⚠️ 一切都在内存里，进程退出即消失；**不碰**真 NAS、不碰磁盘。
import 'mock_dsm_core.dart';

/// 内存树里的一个节点（文件或目录）。
class MockFsNode {
  MockFsNode({
    required this.name,
    required this.path,
    required this.isDir,
    this.size = 0,
    this.mtime = 0,
  });

  final String name;
  final String path;
  final bool isDir;
  int size;
  int mtime;
}

/// 一个极小的内存文件系统（路径 → 节点，外加"父目录"派生）。
class MockFileSystem {
  MockFileSystem._(this._nodes);

  /// 默认树：两条**共享文件夹**（`List.list_share` 的顶层）+ 它们下面的内容。
  ///
  /// 名字故意用"沙箱"语义（`mockfs_sandbox`），看一眼就知道这是 Mock 的树，
  /// 不会与真 NAS 上的路径混淆。
  factory MockFileSystem.seeded() {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final nodes = <String, MockFsNode>{};
    void dir(String path, {int ageDays = 0}) {
      final name = path.split('/').where((s) => s.isNotEmpty).last;
      nodes[path] = MockFsNode(
        name: name,
        path: path,
        isDir: true,
        mtime: now - ageDays * 86400,
      );
    }

    void file(String path, int size, {int ageDays = 0}) {
      final name = path.split('/').where((s) => s.isNotEmpty).last;
      nodes[path] = MockFsNode(
        name: name,
        path: path,
        isDir: false,
        size: size,
        mtime: now - ageDays * 86400,
      );
    }

    dir('/home');
    file('/home/mockfs_home.txt', 64, ageDays: 4);
    dir('/home/mockfs_sandbox', ageDays: 1);
    file('/home/mockfs_sandbox/readme.txt', 128, ageDays: 1);
    dir('/home/Documents', ageDays: 3);
    file('/home/Documents/plan.txt', 2048, ageDays: 3);

    dir('/photo');
    dir('/photo/mockfs_album', ageDays: 2);
    file('/photo/mockfs_album/sample.jpg', 4096, ageDays: 2);

    return MockFileSystem._(nodes);
  }

  final Map<String, MockFsNode> _nodes;

  /// 顶层共享文件夹（`List.list_share`）。
  List<MockFsNode> shares() =>
      _nodes.values.where((n) => _depth(n.path) == 1).toList();

  /// [folderPath] 的直接子节点（`List.list`）。
  List<MockFsNode> children(String folderPath) {
    final base = _trim(folderPath);
    return _nodes.values
        .where((n) => _parent(n.path) == base && n.path != base)
        .toList();
  }

  MockFsNode? at(String path) => _nodes[_trim(path)];

  /// 新建目录。已存在（或父目录不存在）⇒ `null`（调用方回 DSM 的错误码）。
  MockFsNode? createFolder(String folderPath, String name) {
    final parent = _trim(folderPath);
    if (_nodes[parent] == null || !_nodes[parent]!.isDir) return null;
    final path = '$parent/$name';
    if (_nodes.containsKey(path)) return null;
    final n = MockFsNode(name: name, path: path, isDir: true, mtime: _now());
    _nodes[path] = n;
    return n;
  }

  /// 改名（保持原父目录）。目标是目录时**整棵子树**一起换路径。
  MockFsNode? rename(String path, String name) {
    final p = _trim(path);
    final n = _nodes[p];
    if (n == null) return null;
    final target = '${_parent(p)}/$name';
    if (_nodes.containsKey(target)) return null;
    final moved = <String, MockFsNode>{};
    for (final e in _nodes.entries) {
      if (e.key == p || e.key.startsWith('$p/')) {
        final rest = e.key.substring(p.length);
        moved['$target$rest'] = MockFsNode(
          name: rest.isEmpty ? name : e.value.name,
          path: '$target$rest',
          isDir: e.value.isDir,
          size: e.value.size,
          mtime: _now(),
        );
      }
    }
    for (final k in moved.keys) {
      _nodes.remove(k);
    }
    _nodes.remove(p);
    _nodes.addAll(moved);
    return _nodes[target];
  }

  /// 写入一个文件（上传落地）。父目录不存在 ⇒ `null`；
  /// [overwrite] 为假且同名已存在 ⇒ `null`（调用方回"已存在"，正是冲突面板的语义）。
  MockFsNode? writeFile(
    String folderPath,
    String name,
    int size, {
    bool overwrite = false,
  }) {
    final parent = _trim(folderPath);
    if (_nodes[parent] == null || !_nodes[parent]!.isDir) return null;
    final path = '$parent/$name';
    final exists = _nodes.containsKey(path);
    if (exists && !overwrite) return null;
    final n = MockFsNode(
      name: name,
      path: path,
      isDir: false,
      size: size,
      mtime: _now(),
    );
    _nodes[path] = n;
    return n;
  }

  /// 删除（目录连同子树）。
  int delete(List<String> paths) {
    var n = 0;
    for (final raw in paths) {
      final p = _trim(raw);
      if (_nodes[p] == null) continue;
      _nodes.removeWhere((k, _) => k == p || k.startsWith('$p/'));
      n++;
    }
    return n;
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  static int _depth(String p) => _trim(p).split('/').length - 1;

  static String _parent(String p) {
    final t = _trim(p);
    final i = t.lastIndexOf('/');
    return i <= 0 ? '' : t.substring(0, i);
  }

  static String _trim(String p) {
    var s = p.trim();
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}

/// `Delete.start` 提交的待删集合（taskid → 路径）。文件级即可，不必做成类字段。
final Map<String, List<String>> _pendingDeletes = <String, List<String>>{};
int taskSeq = 1;

extension MockFileSystemDemo on MockDsmBackend {
  /// 装上"可写内存文件系统"的四条接口。返回树的引用（用例可直接查状态）。
  MockFileSystem installFileSystemDemo({MockFileSystem? fs}) {
    final tree = fs ?? MockFileSystem.seeded();

    Map<String, dynamic> entry(MockFsNode n) => {
      'name': n.name,
      'path': n.path,
      'isdir': n.isDir,
      'additional': {
        if (!n.isDir) 'size': n.size,
        'time': {'mtime': n.mtime, 'crtime': n.mtime, 'atime': n.mtime},
        'owner': {'user': 'mockuser', 'group': 'users', 'uid': 1024, 'gid': 100},
        // 权限给满：写动词走查要能点到「删除/重命名」
        'perm': {
          'posix': n.isDir ? 755 : 644,
          'is_acl_mode': false,
          'acl': {
            'append': true,
            'del': true,
            'exec': true,
            'read': true,
            'write': true,
          },
        },
      },
    };

    List<MockFsNode> sorted(List<MockFsNode> in_) {
      final out = [...in_];
      // 与真 DSM 默认一致：目录在前，再按名字
      out.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return out;
    }

    fixture('SYNO.FileStation.List', 'list_share', (p) {
      final all = sorted(tree.shares());
      return {
        'success': true,
        'data': {
          'shares': all.map(entry).toList(),
          'total': all.length,
          'offset': 0,
        },
      };
    });

    fixture('SYNO.FileStation.List', 'list', (p) {
      final folder = '${p['folder_path'] ?? p['path'] ?? '/'}';
      final all = sorted(tree.children(folder));
      final offset = int.tryParse('${p['offset'] ?? 0}') ?? 0;
      final limit = int.tryParse('${p['limit'] ?? 0}') ?? 0;
      final page = limit > 0 && offset + limit < all.length
          ? all.sublist(offset, offset + limit)
          : all.sublist(offset.clamp(0, all.length));
      return {
        'success': true,
        'data': {
          'files': page.map(entry).toList(),
          'total': all.length,
          'offset': offset,
        },
      };
    });

    fixture('SYNO.FileStation.CreateFolder', 'create', (p) {
      final folder = '${p['folder_path'] ?? ''}';
      // `name` 允许 JSON 数组（官方前端两种都发过）
      final rawName = '${p['name'] ?? ''}';
      final name = rawName.startsWith('[')
          ? (() {
              final l = const JsonLikeList().parse(rawName);
              return l.isEmpty ? '' : l.first;
            })()
          : rawName;
      final made = tree.createFolder(folder, name);
      if (made == null) {
        return {
          'success': false,
          'error': {'code': 414},
        };
      }
      return {
        'success': true,
        'data': {
          'folders': [entry(made)],
        },
      };
    });

    // ★ r319：**上传**落盘。请求体是 `multipart/form-data`（服务端在
    //   `mock_dsm_server.dart` 里解析后把文件挂在 `__files` 上），
    //   字段 `path` = 目标目录，`filename` 在段的 `Content-Disposition` 里。
    fixture('SYNO.FileStation.Upload', 'upload', (p) {
      if (p['__multipartBroken'] == true) {
        return {'success': false, 'error': {'code': 114}};
      }
      final folder = '${p['path'] ?? ''}';
      final files = (p['__files'] as List?) ?? const [];
      if (files.isEmpty) {
        // 没带文件 = 参数不全（不许回"空上传成功"）
        return {'success': false, 'error': {'code': 114}};
      }
      final overwrite = '${p['overwrite'] ?? ''}' == 'true';
      final written = <String>[];
      for (final f in files) {
        final m = Map<String, Object?>.from(f as Map);
        final name = '${m['name'] ?? ''}';
        final bytes = (m['bytes'] as List?) ?? const [];
        if (name.isEmpty) continue;
        final n = tree.writeFile(folder, name, bytes.length, overwrite: overwrite);
        if (n == null) {
          // 同名且未允许覆盖 ⇒ DSM 的"文件已存在"
          return {'success': false, 'error': {'code': 414}};
        }
        written.add(n.path);
      }
      return {
        'success': true,
        'data': {'blSkip': false, 'file': written, 'pid': 1, 'progress': 1.0},
      };
    });

    fixture('SYNO.FileStation.Rename', 'rename', (p) {
      final paths = _asList(p['path']);
      final names = _asList(p['name']);
      if (paths.isEmpty || names.length != paths.length) {
        return {
          'success': false,
          'error': {'code': 400},
        };
      }
      for (var i = 0; i < paths.length; i++) {
        if (tree.rename(paths[i], names[i]) == null) {
          return {
            'success': false,
            'error': {'code': 414},
          };
        }
      }
      return {
        'success': true,
        'data': {},
      };
    });

    // ★ 官方 DS file 删文件走的是**异步任务** `Delete.start`（返回 taskid），
    //   同步的 `Delete.delete` 是另一条（回收站/兼容路径）。两条都接：
    //   `start` 立刻把状态改成"已完成"，并把要删的路径记进 `lastTaskPaths`
    //   —— 用例可以在收到 taskid 后立刻查状态，不必睡等。
    fixture('SYNO.FileStation.Delete', 'start', (p) {
      final paths = _asList(p['path']);
      // 真服务端是**异步**任务，但删除本身在毫秒级完成；这里就**立刻**改状态，
      // 以免用例的结论取决于"客户端有没有去轮询 status"（那是另一个语义）。
      tree.delete(paths);
      final id = '$taskSeq';
      taskSeq++;
      _pendingDeletes[id] = paths;
      return {
        'success': true,
        'data': {'taskid': id},
      };
    });

    // 任务状态：第一次查询就"完成"（幂等：start 已经删过了）
    fixture('SYNO.FileStation.Delete', 'status', (p) {
      final id = '${p['taskid'] ?? ''}';
      _pendingDeletes.remove(id);
      return {
        'success': true,
        'data': {'finished': true, 'progress': 100},
      };
    });

    fixture('SYNO.FileStation.Delete', 'delete', (p) {
      final paths = _asList(p['path']);
      final n = tree.delete(paths);
      if (n == 0 && paths.isNotEmpty) {
        return {
          'success': false,
          'error': {'code': 414},
        };
      }
      return {
        'success': true,
        'data': {},
      };
    });

    // ★★ 第 329 轮：**二进制下载**夹具（补掉 §2.0.57 记的那条诚实缺口）。
    //
    // 缺口原文（r328 证据 §7）：「宿主『存到本机』按钮在集成里**不可达** ——
    // Mock 没有二进制 `FileStation.Download` 夹具」。没有它，文件浏览器的
    // "下载到本机 → 存到系统目录"这条链在 Mock 上**第一步就断**：
    // `Download` 走到没注册 rawFixture 的分支 ⇒ `103` ⇒ 界面只能说失败，
    // 于是"宿主保存双轨"（`save_destination.dart`）只能靠部件用例证明，
    // **真链路一次都没跑过**。
    //
    // 判据必须在**服务端**：字节由 `mockFileSystemBytes(node)` 按
    // `(i * 31 + 7) % 256` 确定性生成，长度 == 树里登记的 `size`
    // ⇒ 用例可以把"下到本机/存到宿主"的文件**逐字节回读**核对，
    // 而不是只看"界面说成功了"（§2.0.29）。
    rawFixture('SYNO.FileStation.Download', 'download', (p) {
      // ★★ 这里有个**必须踩一次**的坑：`path` 不是裸字符串，而是
      //    `FileEntryDto.encodePaths()` 出来的 **JSON 数组**（`["/a/b.bin"]`）——
      //    第一版按裸串取（`'${p['path']}'`）⇒ 拿到的键变成 `["/home/x.bin"]`
      //    ⇒ `tree.at()` 找不到 ⇒ 夹具回 `408`，而集成里的表现是
      //    "下载按钮点了没反应、任务行上永远没有存到本机"（看起来像界面缺陷）。
      //    判据只能是**服务端真收到什么**：`requestLog` 里那条 path 的形状。
      final paths = _asList(p['path']);
      if (paths.isEmpty) {
        return const MockRawResponse.error(114, note: '缺 path');
      }
      if (paths.length > 1) {
        return MockRawResponse.error(
          408,
          note: '单文件下载夹具一次只支持一个 path（收到 ${paths.length} 个）',
        );
      }
      final path = paths.first;
      final n = tree.at(path);
      if (n == null) {
        return MockRawResponse.error(408, note: '内存树里没有 `$path`');
      }
      if (n.isDir) {
        return MockRawResponse.error(408, note: '`$path` 是目录，不是文件');
      }
      return MockRawResponse(
        mockFileSystemBytes(n),
        contentType: mockFileSystemMime(n.name),
        note: '$path（${n.size} 字节，确定性内容）',
      );
    });

    return tree;
  }
}

/// 内存树里一个文件的**确定性**字节：第 `i` 字节 = `(i * 31 + 7) % 256`。
///
/// 用公式而不是固定字符串：`size` 是夹具自己声明的（64/128/2048/4096…），
/// 生成器让"声明的 size"与"真回的字节数"**必然一致**，
/// 用例又能独立重算一遍来核对（判据不依赖被测实现）。
List<int> mockFileSystemBytes(MockFsNode node) =>
    List<int>.generate(node.size, (i) => (i * 31 + 7) % 256);

/// 下载时回的 MIME：按扩展名给常见值，其余 `application/octet-stream`。
///
/// 为什么不是清一色 octet-stream：客户端的**续传嗅探**分支
/// （`file_download_resume.dart` 的 `_isBinaryContentType`）会因此走到不同路径，
/// 夹具应当**同时**覆盖两边（`.jpg` → 二进制直通；`.txt` → 先嗅错误信封）。
String mockFileSystemMime(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.txt')) return 'text/plain';
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.zip')) return 'application/zip';
  return 'application/octet-stream';
}

/// 极小的 JSON 数组解析（只处理"字符串数组"这一种形态）。
///
/// 为什么不引 `dart:convert`：本文件的入参一律是 DSM 的
/// `["/a","/b"]` 形状，`jsonDecode` 当然也能做，但这里**只需要**字符串数组，
/// 少一层依赖就少一个"值不是 JSON 时抛异常"的分支。
class JsonLikeList {
  const JsonLikeList();

  List<String> parse(String raw) {
    final t = raw.trim();
    if (!t.startsWith('[') || !t.endsWith(']')) return const [];
    final body = t.substring(1, t.length - 1).trim();
    if (body.isEmpty) return const [];
    return body
        .split(',')
        .map((s) => s.trim().replaceAll(RegExp(r'^"|"$'), ''))
        .where((s) => s.isNotEmpty)
        .toList();
  }
}

List<String> _asList(Object? v) {
  if (v == null) return const [];
  final s = '$v';
  if (s.startsWith('[')) return const JsonLikeList().parse(s);
  return s.isEmpty ? const [] : [s];
}
