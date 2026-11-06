// **可写的内存下载队列**：让 Mock 也能"记住"下载任务的写动词。
//
// 为什么需要它（第 320 轮，macOS 写侧第二档）：
//   r319 已经把 `Files` 的四条写动词接到 `mock_fs_demo.dart` 的内存树上；
//   `Downloads` 的"新建任务"仍然只能看到 `success:true, data:{}` ——
//   界面弹一条「任务已创建」，可**列表里永远是空的**：
//   这种 Mock 上"创建成功没有"**既不能判成功也不能判失败**（§2.0.29）。
//
// 做法：把 `Task.list` / `Task.get` / `Task.create` / `Task.delete` /
//   `Task.Statistic.get` / `Settings.Location.get` 接到**同一个内存队列**上，
//   于是「填链接 → 创建 → 列表里出现 → 删除 → 列表里消失」是一条真链路。
//
// ★ 这里的字段名逐字对齐官方 aMule/DC 前端（`docs/stage2-audio-download-api.md`）：
//   顶层 `id/title/type/status/size/username`，附加在 `additional.transfer`；
//   列表根键是 **`task`**（`total` 记账在顶层）。
// ★ 只在 **HTTP Server**（`mock_dsm_server.dart`，`--download-demo`）里安装；
//   `mock_dsm_core.dart` 的离线用例不受影响。
// ★ 一切都在内存里，进程退出即消失；**不碰**真 NAS、不碰磁盘、
//   更不会真的去下载那个 URL（任务永远停在 `downloading`，速率恒 0）。
import 'dart:convert';

import 'mock_dsm_core.dart';

/// 内存队列里的一个任务。
class MockDownloadTask {
  MockDownloadTask({
    required this.id,
    required this.title,
    required this.type,
    required this.status,
    required this.url,
    this.size = 0,
    this.downloaded = 0,
    this.destination = '',
    this.username = 'mockuser',
  });

  final String id;
  final String title;

  /// `http` / `bt` / `nzb` / `emule` …（顶层 `type`）
  final String type;
  int status;
  final String url;
  int size;
  int downloaded;
  /// `Task.edit` 会改它 ⇒ **可写**（r323 接线前它是 final，改目的地只能改内存外的东西）。
  String destination;
  final String username;
}

/// 一个极小的内存下载队列。
class MockDownloadStation {
  MockDownloadStation._(this._tasks);

  /// 默认是**空队列** —— 判据从"空"开始才是最硬的：
  /// 用例看到的每一条都必然是这一轮自己创建出来的。
  factory MockDownloadStation.seeded() => MockDownloadStation._(<MockDownloadTask>[]);

  final List<MockDownloadTask> _tasks;
  int _seq = 0;

  /// 当前队列（可直接给用例查状态）。
  List<MockDownloadTask> get tasks => List.unmodifiable(_tasks);

  /// 建一个 URL 任务。标题取 URL 末段（官方也是从 URL/文件名推 title）。
  /// 任务类型**从 URL 推**（`ed2k:` ⇒ emule、`magnet:`/`.torrent` ⇒ bt、
  /// `.nzb` ⇒ nzb、其余 http）。
  ///
  /// ★ r321（D20）：第一版一律 `type: 'http'` —— 于是"官方默认队列发
  ///   `type:["emule"], type_inverse:true`（= 排除 eMule）"这条语义**永远测不到**，
  ///   eMule 任务也会混进普通队列里。仪器不准，上面的结论就都不算数。
  static String typeOfUrl(String url) {
    final l = url.trim().toLowerCase();
    if (l.startsWith('ed2k:')) return 'emule';
    if (l.startsWith('magnet:') || l.endsWith('.torrent')) return 'bt';
    if (l.endsWith('.nzb')) return 'nzb';
    return 'http';
  }

  /// ★ r322 仪器约定：**URL 里含 `fail` 的任务一创建就是错误态**。
  ///
  /// 为什么需要它：`delete_condition` 的 `status` 分支里有"删除错误任务"这一档
  /// （客户端 `removeErrors()`），而"错误态"只能由**服务端**产生（下载失败）。
  /// 没有这条约定，那条分支就**永远打不到** —— 只能在单测里 mock 掉，
  /// 集成测试里就成了"封装了但没有入口能到达"，与 §2.0.45 的"死功能"同型。
  ///
  /// ⚠️ 这是**仪器**（Mock）自己的约定，不是 DSM 契约：真实 DSM 里
  /// `Task.list` 的 `status` 由下载结果决定，与 URL 文本无关。真机/真 NAS
  /// 的错误态只能等它自然失败 —— 所以这条只允许出现在 Mock 侧，
  /// 且必须**显式标注**（本条注释 + `docs/evidence-r322/README.md`）。
  static const int kStatusError = 101; // DsTaskStatus.error

  /// ★ r423 仪器约定：**URL 里含 `captcha` 的任务一创建就是"等待验证码"态（15）**。
  ///
  /// 为什么需要它：`download_captcha_page`（Download Station「输入验证码」页）
  /// 的入口被 `captchaCount > 0` 门控，该值来自 `Captcha:list.task_ids`
  /// 或任务 `status == 15`（`DsTaskStatus.captchaNeeded`）。
  /// 而真机上 `status 15` **只能由第三方宿主站要求验证码时置位**
  /// （r366 终局裁定：开屏必须塞真实第三方宿主站链接 ⇒ 越出"只自造探针"授权）。
  /// ⇒ 想在**真机**上开出这个页面，只能让**本机 Mock** 产出这个状态。
  ///
  /// ⚠️ 与 [looksLikeFailure] 一样，这是**仪器（Mock）自己的约定，不是 DSM 契约**：
  /// 真实 DSM 的 `status` 由下载结果/宿主站决定，与 URL 文本无关。
  static const int kStatusCaptchaNeeded = 15; // DsTaskStatus.captchaNeeded

  /// ★ r423 仪器约定：**正确的验证码固定是 `1234`**（其余一律 `2301` 验证码不正确）。
  /// 真机不可能知道"正确答案"，Mock 里必须钉一个确定值，否则
  /// `Captcha:set` 的成功/失败两条分支都测不到。
  static const String kCaptchaCode = '1234';

  static bool looksLikeFailure(String url) =>
      url.toLowerCase().contains('fail');

  static bool looksLikeCaptcha(String url) =>
      url.toLowerCase().contains('captcha');

  MockDownloadTask addUrl(
    String url, {
    String destination = '',
    String? type,
    int status = 2, // DsTaskStatus.downloading
  }) {
    _seq++;
    final failed = status == 2 && looksLikeFailure(url);
    final captcha = status == 2 && !failed && looksLikeCaptcha(url);
    final task = MockDownloadTask(
      id: 'dbid_$_seq',
      title: titleOf(url),
      type: type ?? typeOfUrl(url),
      status: captcha
          ? kStatusCaptchaNeeded
          : (failed ? kStatusError : status),
      url: url,
      destination: destination,
    );
    _tasks.add(task);
    return task;
  }

  /// r423：需要验证码的任务（`Captcha:list.task_ids` 的判据来源）。
  List<MockDownloadTask> get captchaTasks =>
      [for (final t in _tasks) if (t.status == kStatusCaptchaNeeded) t];

  bool remove(List<String> ids) {
    final before = _tasks.length;
    _tasks.removeWhere((t) => ids.contains(t.id));
    return _tasks.length != before;
  }

  MockDownloadTask? byId(String id) {
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// URL → 标题：**按协议分流**，不是一律取路径末段。
  ///
  /// ★ 第一版只写了"路径末段"，被 ⑥ 号用例当场抓住：
  ///   `ed2k://|file|emu.bin|1|HASH|/` 走 `Uri.pathSegments` 会得到
  ///   `%7Cfile%7Cemu.bin%7C1%7Chash%7C`（一堆转义竖线），根本不是标题。
  ///   官方前端对 ed2k/magnet 也是**单独解析**的，这里照做：
  ///     * `ed2k://|file|<名字>|<大小>|<hash>|/` ⇒ **`file` 那一段的下一段**；
  ///     * `magnet:?xt=…&dn=<名字>` ⇒ `dn`；没有 `dn` 就退到 `xt` 的尾段；
  ///     * `http(s)/ftp(s)/sftp` ⇒ 路径末段（**解码后**），没有就退主机名。
  static String titleOf(String url) {
    final lower = url.toLowerCase();
    if (lower.startsWith('ed2k:')) {
      // ⚠️ 别背下标：`ed2k://|file|…` 按 `|` 切是
      //   `['ed2k://','file','<名字>','<大小>','<hash>','/']` ⇒ 名字在下标 **2**。
      //   我第一版按"第 4 段"写，被 ⑥ 号用例当场抓住（标题变成了 `1`）。
      //   直接找 `file`/`server` 标志位，两种写法都对。
      final parts = url.split('|');
      for (var i = 0; i < parts.length - 1; i++) {
        final tag = parts[i].trim().toLowerCase();
        if ((tag == 'file' || tag == 'server') &&
            parts[i + 1].trim().isNotEmpty) {
          return Uri.decodeComponent(parts[i + 1].trim());
        }
      }
    }
    if (lower.startsWith('magnet:')) {
      final q = Uri.tryParse(url)?.queryParameters ?? const <String, String>{};
      final dn = (q['dn'] ?? '').trim();
      if (dn.isNotEmpty) return Uri.decodeComponent(dn);
      final xt = (q['xt'] ?? '').trim();
      if (xt.isNotEmpty) return xt.split(':').last;
    }
    final uri = Uri.tryParse(url);
    final segs = (uri?.pathSegments ?? const <String>[])
        .where((s) => s.isNotEmpty)
        .toList();
    if (segs.isNotEmpty) return Uri.decodeComponent(segs.last);
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return url;
  }
}

/// `[a, b]` 形态的 JSON 文本 → `List<String>`。
///
/// ★ 与 `mock_fs_demo.dart` 里那个按 `,` 切的私家伙计**不同**：这里用真解析器，
///   因为 URL 里**本来就可能带逗号**（`?a=1,2`），按逗号切会把一条 URL 切成两条。
///   解析失败或不是数组时退化成"单值"（官方前端两种形态都发过）。
List<String> stringList(Object? v) {
  if (v == null) return const [];
  final s = '$v'.trim();
  if (s.startsWith('[')) {
    try {
      final decoded = jsonDecode(s);
      if (decoded is List) {
        return [
          for (final e in decoded)
            if ('$e'.isNotEmpty) '$e',
        ];
      }
    } catch (_) {
      // 非法 JSON ⇒ 退化成单值（下面那行），不抛
    }
  }
  return s.isEmpty ? const [] : [s];
}

/// `"url"`（带引号的 JSON 文本）/ `url`（裸值）两种形态都收。
String unquoteJson(String raw) {
  final s = raw.trim();
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    try {
      final d = jsonDecode(s);
      if (d is String) return d;
    } catch (_) {
      return s.substring(1, s.length - 1);
    }
  }
  return s;
}

extension MockDownloadStationDemo on MockDsmBackend {
  /// 装上"可写内存下载队列"的六条接口。返回队列的引用（用例可直接查状态）。
  MockDownloadStation installDownloadDemo({MockDownloadStation? ds}) {
    final q = ds ?? MockDownloadStation.seeded();

    Map<String, dynamic> taskJson(MockDownloadTask t) => {
      'id': t.id,
      'title': t.title,
      'type': t.type,
      'status': t.status,
      'size': t.size,
      'username': t.username,
      'additional': {
        'detail': {
          'destination': t.destination,
          'url': t.url,
          'connected_leechers': 0,
          'connected_seeders': 0,
          'create_time': 0,
        },
        'transfer': {
          'size_downloaded': t.downloaded,
          'size_uploaded': 0,
          'speed_download': 0,
          'speed_upload': 0,
        },
      },
    };

    // `list` / `pause_condition` / `resume_condition` / `delete_condition`
    // **共用同一套筛选**（官方这几个方法收的就是同一组参数：type + type_inverse
    // + keyword + status）。抄两遍迟早走偏 —— 这里只写一份。
    List<MockDownloadTask> selectTasks(MockDownloadStation q, Map<String, dynamic> p) {
      var all = [...q.tasks];
      // `type` 是 JSON 数组；官方默认队列发 `type:["emule"], type_inverse:true`
      // ⇒ 语义是"**排除** eMule"。这正是"参数名/语义要对齐官方"的一处。
      final types = stringList(p['type']);
      final inverse = '${p['type_inverse'] ?? ''}' == 'true';
      if (types.isNotEmpty) {
        all = [
          for (final t in all)
            if (types.contains(t.type) != inverse) t,
        ];
      }
      final kw = '${p['keyword'] ?? ''}'.trim().toLowerCase();
      if (kw.isNotEmpty) {
        all = [
          for (final t in all)
            if (t.title.toLowerCase().contains(kw)) t,
        ];
      }
      final statuses = stringList(p['status'])
          .map((s) => int.tryParse(s))
          .whereType<int>()
          .toList();
      if (statuses.isNotEmpty) {
        all = [
          for (final t in all)
            if (statuses.contains(t.status)) t,
        ];
      }
      return all;
    }

    fixture('SYNO.DownloadStation2.Task', 'list', (p) {
      final all = selectTasks(q, p);
      final offset = int.tryParse('${p['offset'] ?? 0}') ?? 0;
      final limit = int.tryParse('${p['limit'] ?? 0}') ?? 0;
      final total = all.length;
      final page = limit > 0 && offset + limit < total
          ? all.sublist(offset, offset + limit)
          : all.sublist(offset.clamp(0, total));
      return {
        'success': true,
        'data': {
          'task': page.map(taskJson).toList(),
          'total': total,
          'offset': offset,
        },
      };
    });

    fixture('SYNO.DownloadStation2.Task', 'get', (p) {
      final ids = stringList(p['id']);
      final found = <MockDownloadTask>[
        for (final id in ids)
          ?q.byId(id),
      ];
      return {
        'success': true,
        'data': {'task': found.map(taskJson).toList(), 'total': found.length},
      };
    });

    // ★ 写动词本体。参数名逐字对齐官方：`type`（`url`/`file`）、`url`
    //   （**JSON 数组文本**）、`destination`（**JSON 文本**）、`create_list`。
    fixture('SYNO.DownloadStation2.Task', 'create', (p) {
      final type = unquoteJson('${p['type'] ?? ''}');
      final urls = stringList(p['url']);
      if (type.isEmpty || urls.isEmpty) {
        // 缺必填 = 114（不许回"创建成功但什么都没有"）
        return {
          'success': false,
          'error': {'code': 114},
        };
      }
      final dest = unquoteJson('${p['destination'] ?? ''}');
      final ids = <String>[];
      for (final u in urls) {
        ids.add(q.addUrl(u, destination: dest).id);
      }
      final data = <String, dynamic>{'taskid': ids};
      // `create_list=true` 时官方回 `list_id`（任务还没开始，要先选文件）
      if ('${p['create_list'] ?? ''}' == 'true') {
        data['list_id'] = 'mocklist_${ids.first}';
      }
      return {'success': true, 'data': data};
    });

    fixture('SYNO.DownloadStation2.Task', 'delete', (p) {
      final ids = stringList(p['id']);
      if (ids.isEmpty) {
        return {
          'success': false,
          'error': {'code': 114},
        };
      }
      // ★★ `Task.delete` 里 **`force_complete=true` 不是删除**，是"结束任务"
      //   （官方文案：文件会被移到目标文件夹、此后无法续传 ⇒ **任务留在列表里**）。
      //   同一个接口两种语义 ⇒ 这里必须**分流**：第一版一律 `remove()`，
      //   等于把"结束任务"实现成了"删除任务"（会悄悄删掉用户的任务）。
      if ('${p['force_complete'] ?? ''}' == 'true') {
        for (final id in ids) {
          final t = q.byId(id);
          if (t != null) t.status = 5; // finished
        }
        return {
          'success': true,
          'data': {},
        };
      }
      q.remove(ids);
      return {
        'success': true,
        'data': {},
      };
    });

    // ---- 行级 `edit`（改目的地 / 优先级 / 解压口令）
    //
    // 官方语义（`ui/download.js` 的任务编辑表单）：
    //   * `destination` / `priority` / `extract_password` **至少给一个**
    //     （客户端 `editTask` 里两个可改字段都空时直接抛 `114`，不发请求）；
    //   * `id` 是**任务 id 数组文本**。
    // ⚠️ 只认**真的带了值**的参数：`destination` 传空串不算"改"（否则
    //    "什么都没改"也会被记成一次成功的写操作 ⇒ 假绿）。
    fixture('SYNO.DownloadStation2.Task', 'edit', (p) {
      final ids = stringList(p['id']);
      final dest = unquoteJson('${p['destination'] ?? ''}').trim();
      final prio = unquoteJson('${p['priority'] ?? ''}').trim();
      final pw = '${p['extract_password'] ?? ''}';
      if (ids.isEmpty || (dest.isEmpty && prio.isEmpty && pw.isEmpty)) {
        return {
          'success': false,
          'error': {'code': 114},
        };
      }
      for (final id in ids) {
        final t = q.byId(id);
        if (t == null) {
          return {
            'success': false,
            'error': {
              'code': 117,
            }, // 任务不存在（官方 `ERR_TASK_NOT_FOUND` 档位之一）
          };
        }
        if (dest.isNotEmpty) t.destination = dest;
      }
      return {
        'success': true,
        'data': {},
      };
    });

    // ---- 行级 pause / resume（`id` = JSON 数组文本）
    for (final (method, to) in [('pause', 3), ('resume', 2)]) {
      fixture('SYNO.DownloadStation2.Task', method, (p) {
        final ids = stringList(p['id']);
        if (ids.isEmpty) {
          return {
            'success': false,
            'error': {'code': 114},
          };
        }
        for (final id in ids) {
          final t = q.byId(id);
          if (t == null) continue;
          if (to == 3) {
            // 暂停：只对**可暂停**的任务生效（已完成/错误的任务不变）
            if (t.status != 5 && t.status < 101) t.status = 3;
          } else {
            if (t.status == 3) t.status = 2;
          }
        }
        return {
          'success': true,
          'data': {},
        };
      });
    }

    // ---- 批量 pause_condition / resume_condition（官方 Web UI 的 pause_all/resume_all）
    for (final (method, to) in [('pause_condition', 3), ('resume_condition', 2)]) {
      fixture('SYNO.DownloadStation2.Task', method, (p) {
        final hit = selectTasks(q, p);
        for (final t in hit) {
          if (to == 3) {
            if (t.status != 5 && t.status < 101) t.status = 3;
          } else {
            if (t.status == 3) t.status = 2;
          }
        }
        return {
          'success': true,
          'data': {},
        };
      });
    }

    // ---- delete_condition（官方 Web UI 的 clear/remove errors）
    fixture('SYNO.DownloadStation2.Task', 'delete_condition', (p) {
      final hit = selectTasks(q, p);
      final ids = [for (final t in hit) t.id];
      q.remove(ids);
      return {
        'success': true,
        'data': {},
      };
    });

    // 顶部总速率（官方前端读 `download_rate`/`upload_rate`）
    fixture('SYNO.DownloadStation2.Task.Statistic', 'get', (p) {
      var down = 0;
      for (final t in q.tasks) {
        if (t.status == 2) down++;
      }
      return {
        'success': true,
        'data': {'download_rate': down * 1024, 'upload_rate': 0},
      };
    });

    // 默认下载目录（官方 `webapiLocationGet`；字段 `default_destination`）
    fixture('SYNO.DownloadStation2.Settings.Location', 'get', (p) {
      return {
        'success': true,
        'data': {'default_destination': '/volume1/downloads'},
      };
    });

    // ---- r423：验证码三件套（`Captcha:list` / `set` / `download`）
    //
    // 目的：让**真机**能开出 `download_captcha_page`（Download Station
    // 「输入验证码」页）。真机上该入口被 `captchaCount > 0` 门控，而
    // `status 15` 只能由**第三方宿主站**要求验证码时置位
    // （r366 终局裁定：越出"只自造探针"授权，主动不做）⇒
    // 唯一合规路径 = **本机 Mock（`adb reverse` + `127.0.0.1` 明文例外）**。
    //
    // 线参逐字来自包内官方前端 `ui/download.js` 的 `DLM.CaptchaEnterDialog`：
    //   `list`     → 无参，回 `data.task_ids`
    //   `set`      → `{task_id, code}`
    //   `download` → `{task_id, t}`，**直链 GET 回图片字节**（不是 JSON 信封）
    fixture('SYNO.DownloadStation2.Captcha', 'list', (p) {
      final ids = [for (final t in q.captchaTasks) t.id];
      return {
        'success': true,
        'data': {'task_ids': ids, 'total': ids.length},
      };
    });

    // ★ 成功码固定 `1234`（[MockDownloadStation.kCaptchaCode]）；其余一律
    //   2301（官方唯一业务码：`download_error_wrong_captcha`）。
    //   提交成功 ⇒ 该任务回到"下载中"（15 → 2），于是 `list` 里自然少一条 ——
    //   判据取**服务端状态**，不取 `set` 的回包。
    fixture('SYNO.DownloadStation2.Captcha', 'set', (p) {
      final id = '${p['task_id'] ?? ''}';
      final code = '${p['code'] ?? ''}'.trim();
      if (id.isEmpty || code.isEmpty) {
        return {
          'success': false,
          'error': {'code': 114},
        };
      }
      final t = q.byId(id);
      if (t == null) {
        return {
          'success': false,
          'error': {'code': 117},
        };
      }
      if (code != MockDownloadStation.kCaptchaCode) {
        return {
          'success': false,
          'error': {'code': 2301},
        };
      }
      t.status = 2; // DsTaskStatus.downloading
      return {
        'success': true,
        'data': {},
      };
    });

    // 验证码**图片**（120×40 灰度 PNG，116 字节，`_mockCaptchaPngB64`）。
    // ⚠️ 真机上 `task_id` 不存在时**不是** JSON 错误码，而是
    // HTTP 404 + DSM 的 HTML 错误页（`.so` 的 `PrintDownloadFileNotFound`）
    // ⇒ 这里用 404 对齐"取不到图"这一档。
    rawFixture('SYNO.DownloadStation2.Captcha', 'download', (p) {
      final id = '${p['task_id'] ?? ''}';
      if (id.isEmpty) {
        return const MockRawResponse.error(120, note: '缺 task_id');
      }
      if (q.byId(id) == null) {
        return const MockRawResponse.error(404, note: '任务不存在');
      }
      return MockRawResponse(
        _mockCaptchaPng,
        contentType: 'image/png',
        note: 'r423 仪器：验证码图（灰度 PNG，120×40）',
      );
    });

    return q;
  }
}

/// r423 仪器：验证码图片（120×40 灰度 PNG，**116 字节**）。
///
/// 不引第三方依赖、不读磁盘（Mock 要能脱离宿主文件系统跑）：
/// 字节是**用 `zlib` 现场生成后固化**的（白底 + 4 个黑色方块，形如验证码数字）。
const String _mockCaptchaPngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAHgAAAAoCAAAAAAQgWH5AAAAO0lEQVR42u3NsQ0AMAgDMC7h/9/6'
    'RHcqJgZUyRmTSI6zlACDweAxnCVv2z37DQwGg8FgMBgMBoPBn8IXxiFlcrhFhckAAAAASUVORK5C'
    'YII=';

final List<int> _mockCaptchaPng = base64.decode(_mockCaptchaPngB64);
