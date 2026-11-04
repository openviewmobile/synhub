// `tool/mock_dsm/mock_ds_demo.dart` 的守卫：**Mock 的下载写动词必须真的改队列**。
//
// 为什么值得单独立测：这个内存队列是 macOS/Linux/iOS「新建下载任务」验收的
// **判据来源** —— 如果它自己就"create 了但 list 里没有"，上层所有"创建成功"
// 的结论都会变成 §2.0.29 的反面教材（用一个坏仪器去证明"改对了"）。
//
// 判据一律取**服务端状态**（`Task.list` 的回包），不取 create 的回包。
import 'package:flutter_test/flutter_test.dart';

import '../tool/mock_dsm/mock_ds_demo.dart';
import '../tool/mock_dsm/mock_dsm_core.dart';

void main() {
  late MockDsmBackend backend;
  late MockDownloadStation queue;
  late String sid;

  setUp(() {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    sid = backend.login(username: 'mockuser', admin: false);
    queue = backend.installDownloadDemo();
  });

  MockDsmResponse call(
    String api,
    String method,
    Map<String, dynamic> p, {
    int version = 2,
  }) => backend.handle('entry.cgi', {
        'api': api,
        'method': method,
        'version': version,
        '_sid': sid,
        ...p,
      });

  /// `Task.list` 的**服务端状态**（队列里到底有什么）。
  List<Map<String, dynamic>> listed([Map<String, dynamic> extra = const {}]) {
    final r = call('SYNO.DownloadStation2.Task', 'list', {
      'offset': 0,
      'limit': 50,
      ...extra,
    });
    expect(r.ok, isTrue, reason: 'Task.list 应成功：${r.json}');
    final data = r.json['data'] as Map;
    return [
      for (final e in (data['task'] as List? ?? const []))
        Map<String, dynamic>.from(e as Map),
    ];
  }

  test('① 空队列：list 回空表（判据的起点是"空"，不是"有一堆预置数据"）', () {
    expect(queue.tasks, isEmpty);
    expect(listed(), isEmpty);
  });

  test('② create → list 里真的多一条，标题/URL 都来自请求', () {
    final r = call('SYNO.DownloadStation2.Task', 'create', {
      'type': 'url',
      'url': '["https://example.com/files/r320_task.bin"]',
      'destination': '"/volume1/downloads"',
      'create_list': false,
    });
    expect(r.ok, isTrue, reason: '${r.json}');
    final ids = ((r.json['data'] as Map)['taskid'] as List).cast<Object?>();
    expect(ids, hasLength(1), reason: '一条 URL 应回一个 taskid');

    final rows = listed();
    expect(rows, hasLength(1), reason: '★ create 之后 list 里必须真有它');
    expect(rows.single['title'], 'r320_task.bin');
    expect(rows.single['type'], 'http');
    expect(rows.single['status'], 2, reason: '默认是"下载中"（不谎报已完成）');
    expect(rows.single['id'], '${ids.single}');
    expect(queue.tasks.single.url, 'https://example.com/files/r320_task.bin');
    expect(queue.tasks.single.destination, '/volume1/downloads');
  });

  test('③ 缺 type / 缺 url ⇒ 114（不许回"创建成功但队列里没有"）', () {
    final noType = call('SYNO.DownloadStation2.Task', 'create', {
      'url': '["https://example.com/a.bin"]',
    });
    expect(noType.ok, isFalse);
    expect((noType.json['error'] as Map)['code'], 114);

    final noUrl = call('SYNO.DownloadStation2.Task', 'create', {
      'type': 'url',
      'url': '[]',
    });
    expect(noUrl.ok, isFalse);
    expect((noUrl.json['error'] as Map)['code'], 114);
    expect(queue.tasks, isEmpty, reason: '失败的创建不许留下半个任务');
  });

  test('④ 多条 URL：一条一个 taskid，且 URL 里的逗号不会被切开', () {
    const u1 = 'https://example.com/a.bin?list=1,2,3';
    const u2 = 'https://example.com/b.bin';
    final r = call('SYNO.DownloadStation2.Task', 'create', {
      'type': '"url"', // 带引号的 JSON 文本形态（官方两种都发过）
      'url': '["$u1","$u2"]',
    });
    expect(r.ok, isTrue, reason: '${r.json}');
    expect(((r.json['data'] as Map)['taskid'] as List), hasLength(2));
    expect(queue.tasks.map((t) => t.url).toList(), [u1, u2],
        reason: '★ 按逗号切会在这里断成两条 —— 真解析器不会');
    expect(queue.tasks.map((t) => t.title).toList(),
        ['a.bin', 'b.bin'], reason: '带 query 的 URL 标题取路径末段');
  });

  test('⑤ create_list=true ⇒ 回 list_id（任务还没开始，选文件流程要用）', () {
    final r = call('SYNO.DownloadStation2.Task', 'create', {
      'type': 'url',
      'url': '["https://example.com/c.bin"]',
      'create_list': true,
    });
    expect(r.ok, isTrue);
    expect('${(r.json['data'] as Map)['list_id']}', isNotEmpty);
  });

  test('⑥ 默认队列排除 eMule（type_inverse 语义照官方，不是"过滤成空"）', () {
    queue.addUrl('https://example.com/http.bin');
    queue.addUrl('ed2k://|file|emu.bin|1|HASH|/', type: 'emule');
    final normal = listed({
      'type': '["emule"]',
      'type_inverse': true,
    });
    expect(normal.map((e) => e['title']).toList(), ['http.bin'],
        reason: 'type_inverse=true 是"排除 eMule"');
    final only = listed({'type': '["emule"]'});
    expect(only.map((e) => e['title']).toList(), ['emu.bin']);
    expect(listed().map((e) => e['title']).toList(), ['http.bin', 'emu.bin'],
        reason: '不带 type 时两条都在');
  });

  test('⑦ keyword 是子串匹配；status 过滤按官方状态码', () {
    final a = queue.addUrl('https://example.com/alpha.bin');
    queue.addUrl('https://example.com/beta.bin');
    a.status = 5; // finished
    expect(listed({'keyword': 'alph'}).map((e) => e['title']).toList(),
        ['alpha.bin']);
    expect(listed({'status': '[5]'}).map((e) => e['title']).toList(), ['alpha.bin']);
    expect(listed({'status': '[2]'}).map((e) => e['title']).toList(), ['beta.bin']);
  });

  test('⑧ delete → 列表里真的没了（judgement 也走服务端）', () {
    final t = queue.addUrl('https://example.com/del.bin');
    expect(listed(), hasLength(1));
    final r = call('SYNO.DownloadStation2.Task', 'delete', {'id': '["${t.id}"]'});
    expect(r.ok, isTrue, reason: '${r.json}');
    expect(listed(), isEmpty, reason: '★ delete 之后 list 里必须没有它');
    expect(queue.tasks, isEmpty);
  });

  test('⑨ get 按 id 取；未注册的 id 回空表（不编一条假任务）', () {
    final t = queue.addUrl('https://example.com/get.bin');
    final r = call('SYNO.DownloadStation2.Task', 'get', {'id': '["${t.id}"]'});
    expect(r.ok, isTrue);
    final task = ((r.json['data'] as Map)['task'] as List).single as Map;
    expect(task['title'], 'get.bin');
    final miss = call('SYNO.DownloadStation2.Task', 'get', {'id': '["nope"]'});
    expect(miss.ok, isTrue);
    expect(((miss.json['data'] as Map)['task'] as List), isEmpty);
  });

  test('⑩ Statistic / Location 的字段名与官方一致', () {
    queue.addUrl('https://example.com/s.bin');
    // ★ Statistic/Location 在客户端是 `_v1`（`negotiate(..., _v1)`）——
    //   用 v2 调会撞上 mock 的版本守卫（103），这正是它该做的（§3 的版本陷阱）。
    final st = call(
      'SYNO.DownloadStation2.Task.Statistic',
      'get',
      const {},
      version: 1,
    );
    expect(st.ok, isTrue);
    expect((st.json['data'] as Map).containsKey('download_rate'), isTrue);
    expect((st.json['data'] as Map).containsKey('upload_rate'), isTrue);

    final loc = call(
      'SYNO.DownloadStation2.Settings.Location',
      'get',
      const {},
      version: 1,
    );
    expect(loc.ok, isTrue);
    expect((loc.json['data'] as Map)['default_destination'], '/volume1/downloads');
  });

  test('⑪ 能力位：装上 demo 之前 `Task.list` 是空 data（契约不变）', () {
    final fresh = MockDsmBackend(catalog: DsmCatalog.load());
    final sid2 = fresh.login(username: 'mockuser', admin: false);
    final r = fresh.handle('entry.cgi', {
      'api': 'SYNO.DownloadStation2.Task',
      'method': 'list',
      'version': 2,
      '_sid': sid2,
      'offset': 0,
      'limit': 50,
    });
    expect(r.ok, isTrue);
    expect((r.json['data'] as Map).containsKey('task'), isFalse,
        reason: '没注册夹具 ⇒ 空 data（§2.0.38 的契约不能被 demo 改掉）');
  });

  // ---- r321：pause / resume / *_condition / force_complete / delete_condition
  String create(String url) {
    final r = call('SYNO.DownloadStation2.Task', 'create', {
      'type': 'url',
      'url': '["$url"]',
      'destination': '"/volume1/downloads"',
    });
    expect(r.ok, isTrue, reason: 'create 应成功：${r.json}');
    return '${(r.json['data'] as Map)['taskid'][0]}';
  }

  int statusOf(String id) {
    final hit = listed().where((t) => '${t['id']}' == id).toList();
    expect(hit, hasLength(1), reason: '队列里应当只有一条 $id');
    return hit.first['status'] as int;
  }

  test('⑫ 行级 pause/resume 真的改状态（3 ⇄ 2），缺 id 回 114', () {
    final id = create('https://example.com/a.bin');
    expect(statusOf(id), 2, reason: '新建的 http 任务是 downloading=2');

    var r = call('SYNO.DownloadStation2.Task', 'pause', {'id': '["$id"]'});
    expect(r.ok, isTrue);
    expect(statusOf(id), 3, reason: 'pause 之后必须是 paused=3');

    r = call('SYNO.DownloadStation2.Task', 'resume', {'id': '["$id"]'});
    expect(r.ok, isTrue);
    expect(statusOf(id), 2, reason: 'resume 之后回到 downloading=2');

    r = call('SYNO.DownloadStation2.Task', 'pause', {'id': '[]'});
    expect(r.ok, isFalse);
    expect(r.json['error']['code'], 114, reason: '缺必填 id = 114');
    expect(statusOf(id), 2, reason: '被拒的调用不许改状态');
  });

  test('⑬ pause/resume 不碰已完成的任务（finished=5 不许被"恢复"成下载中）', () {
    final done = create('https://example.com/done.bin');
    // 用 force_complete 把它变成 finished=5（这本身就是"结束任务"的语义）
    final fc = call('SYNO.DownloadStation2.Task', 'delete', {
      'id': '["$done"]',
      'force_complete': 'true',
    });
    expect(fc.ok, isTrue);
    expect(statusOf(done), 5, reason: 'force_complete 之后是 finished');

    call('SYNO.DownloadStation2.Task', 'pause', {'id': '["$done"]'});
    expect(statusOf(done), 5, reason: '已完成的任务不会被"暂停"改掉');
    call('SYNO.DownloadStation2.Task', 'resume', {'id': '["$done"]'});
    expect(statusOf(done), 5, reason: '★ 已完成的任务绝不会被 resume 拉回下载中');
  });

  test('⑭ force_complete=true 是"结束任务"：**留在队列里**，不是删除', () {
    final id = create('https://example.com/keep.bin');
    final r = call('SYNO.DownloadStation2.Task', 'delete', {
      'id': '["$id"]',
      'force_complete': 'true',
    });
    expect(r.ok, isTrue);
    expect(
      listed().map((t) => '${t['id']}'),
      contains(id),
      reason: '★★ 同一个 `Task.delete`，`force_complete=true` 的语义是"结束"——'
          '任务必须还在（第一版 mock 一律 remove ⇒ 把"结束任务"实现成了"删除"）',
    );
    expect(statusOf(id), 5);

    // 同一个接口不带 force_complete 才是真删除
    final del = call('SYNO.DownloadStation2.Task', 'delete', {'id': '["$id"]'});
    expect(del.ok, isTrue);
    expect(listed(), isEmpty, reason: '不带 force_complete 才是删除');
  });

  test('⑮ pause_condition/resume_condition 按同一套筛选批量改（默认排除 emule）', () {
    final http = create('https://example.com/h.bin');
    final emu = create('ed2k://|file|e.bin|1|AA|/');
    expect(statusOf(http), 2);
    expect(statusOf(emu), 2);

    // 官方默认队列发 type:["emule"], type_inverse:true ⇒ 只作用于非 emule
    var r = call('SYNO.DownloadStation2.Task', 'pause_condition', {
      'type': '["emule"]',
      'type_inverse': 'true',
    });
    expect(r.ok, isTrue);
    expect(statusOf(http), 3, reason: '非 emule 的那条被暂停');
    expect(statusOf(emu), 2, reason: '★ emule 那条**不受影响**（type_inverse 的语义）');

    r = call('SYNO.DownloadStation2.Task', 'resume_condition', {
      'type': '["emule"]',
      'type_inverse': 'true',
    });
    expect(r.ok, isTrue);
    expect(statusOf(http), 2, reason: '批量恢复回来了');
  });

  test('⑯ 类型从 URL 推：ed2k ⇒ emule、magnet/.torrent ⇒ bt、.nzb ⇒ nzb', () {
    final http = create('https://example.com/x.bin');
    final emu = create('ed2k://|file|y.bin|1|AA|/');
    final mag = create('magnet:?xt=urn:btih:ABCDEF&dn=z.iso');
    final nzb = create('https://example.com/w.nzb');
    final byId = {for (final t in listed()) '${t['id']}': '${t['type']}'};
    expect(byId[http], 'http');
    expect(byId[emu], 'emule');
    expect(byId[mag], 'bt');
    expect(byId[nzb], 'nzb');
    // ★ 反向：默认队列（排除 emule）里**必须**看不到 emule 那条
    final normal = listed({'type': '["emule"]', 'type_inverse': 'true'});
    expect(normal.map((t) => '${t['id']}'), isNot(contains(emu)));
    expect(normal.map((t) => '${t['id']}'), contains(http));
  });

  test('⑰ delete_condition 只删命中的那些（status 筛选也要生效）', () {
    final a = create('https://example.com/a2.bin');
    final b = create('https://example.com/b2.bin');
    // 把 b 暂停，然后只删"下载中(2)"的那些
    call('SYNO.DownloadStation2.Task', 'pause', {'id': '["$b"]'});
    expect(statusOf(b), 3);

    final r = call('SYNO.DownloadStation2.Task', 'delete_condition', {
      'type': '["emule"]',
      'type_inverse': 'true',
      'status': '[2]',
    });
    expect(r.ok, isTrue);
    expect(
      listed().map((t) => '${t['id']}'),
      [b],
      reason: '只有下载中的 $a 被删；暂停的 $b 必须留（status 筛选生效）',
    );
  });

  test('⑲ edit 改 destination；空参数/未知 id 都要拒绝且不改状态', () {
    final a = create('https://example.com/e1.bin');
    // ① 真的改了
    final r = call('SYNO.DownloadStation2.Task', 'edit', {
      'id': '["$a"]',
      'destination': '"/volume1/movies"',
    });
    expect(r.ok, isTrue);
    final dest = listed().firstWhere((t) => t['id'] == a);
    expect(
      '${((dest['additional'] as Map)['detail'] as Map)['destination']}',
      '/volume1/movies',
      reason: '★ 判据是服务端读回来的 destination，不是"请求返回了 success"',
    );
    // ② 一个可改字段都不给 ⇒ 114，且 destination 不许被清空
    final empty = call('SYNO.DownloadStation2.Task', 'edit', {'id': '["$a"]'});
    expect(empty.ok, isFalse);
    expect(empty.errorCode, 114);
    final again = listed().firstWhere((t) => t['id'] == a);
    expect(
      '${((again['additional'] as Map)['detail'] as Map)['destination']}',
      '/volume1/movies',
      reason: '拒绝的请求不许改状态（假绿防线）',
    );
    // ③ 未知 id ⇒ 117，且队列不变
    final missing = call('SYNO.DownloadStation2.Task', 'edit', {
      'id': '["nope"]',
      'destination': '"/volume1/x"',
    });
    expect(missing.ok, isFalse);
    expect(missing.errorCode, 117);
    expect(listed().map((t) => '${t['id']}'), [a]);
  });

  test('⑱ URL 含 fail ⇒ 一创建就是错误态（101）；errorGroup 能把它删掉', () {
    // 这条是**仪器自己的约定**（见 `mock_ds_demo.dart` 的注释）：真实 DSM 里
    // 错误态由下载结果决定，Mock 里只能靠 URL 文本触发，否则
    // 客户端 `removeErrors()`（`delete_condition(status: errorGroup)`）
    // 那条分支在集成测试里**永远到不了**。
    final bad = create('https://example.com/fail-me.bin');
    final good = create('https://example.com/ok.bin');
    expect(
      statusOf(bad),
      101,
      reason: '错误态（DsTaskStatus.error）',
    );
    expect(statusOf(good), 2, reason: '正常 URL 不受影响');

    // ★ 反向：不带 status 的 delete_condition = 删除全部 ⇒ 两条都没了；
    //   这里先只删 errorGroup，必须**只**删掉错误那条。
    final r = call('SYNO.DownloadStation2.Task', 'delete_condition', {
      'type': '["emule"]',
      'type_inverse': 'true',
      'status': '[101, 102, 103]',
    });
    expect(r.ok, isTrue);
    expect(
      listed().map((t) => '${t['id']}'),
      [good],
      reason: '错误任务被删，正常任务必须留',
    );
  });

  // ---- r423：验证码三件套（让真机能开出 `download_captcha_page`）

  /// `Captcha:list` 的 `task_ids`（**服务端状态**，不取别的回包）。
  List<String> captchaList() {
    final r = call('SYNO.DownloadStation2.Captcha', 'list', const {});
    expect(r.ok, isTrue, reason: 'Captcha:list 应成功：${r.json}');
    final data = r.json['data'] as Map;
    return [for (final e in (data['task_ids'] as List? ?? const [])) '$e'];
  }

  test('⑳ URL 含 captcha ⇒ 任务一创建就是"等待验证码"（15），并出现在 Captcha:list 里', () {
    // 这条是**仪器自己的约定**（见 `mock_ds_demo.dart` 的注释）：真机上
    // `status 15` 只能由**第三方宿主站**要求验证码时置位（r366 终局裁定：
    // 越出"只自造探针"授权）⇒ 真机想开出那个页面，只能让本机 Mock 产出它。
    final need = create('https://example.com/need-captcha.bin');
    final plain = create('https://example.com/plain.bin');
    expect(statusOf(need), 15, reason: '等待验证码（DsTaskStatus.captchaNeeded）');
    expect(statusOf(plain), 2, reason: '普通 URL 不受影响');
    expect(captchaList(), [need], reason: '★ list 只报需要验证码的那条');
  });

  test('㉑ Captcha:set 错码 ⇒ 2301 且**状态不变**；对码 ⇒ 15→2 且 list 里少一条', () {
    final id = create('https://example.com/need-captcha.bin');
    expect(captchaList(), [id]);

    // ① 错码：官方唯一业务码 2301 = download_error_wrong_captcha
    final bad = call('SYNO.DownloadStation2.Captcha', 'set', {
      'task_id': id,
      'code': '0000',
    });
    expect(bad.ok, isFalse, reason: '错码不许回成功');
    expect((bad.json['error'] as Map)['code'], 2301);
    expect(statusOf(id), 15, reason: '★ 错码之后任务**仍**在等待验证码');
    expect(captchaList(), [id]);

    // ② 对码：状态改变只认 Task.list 的回读
    final ok = call('SYNO.DownloadStation2.Captcha', 'set', {
      'task_id': id,
      'code': '1234',
    });
    expect(ok.ok, isTrue, reason: '${ok.json}');
    expect(statusOf(id), 2, reason: '通过验证码后回到"下载中"');
    expect(captchaList(), isEmpty, reason: '不再需要验证码');

    // ③ 缺参 / 任务不存在：不许回"成功但什么都没改"
    final noCode = call('SYNO.DownloadStation2.Captcha', 'set', {
      'task_id': id,
    });
    expect((noCode.json['error'] as Map)['code'], 114);
    final missing = call('SYNO.DownloadStation2.Captcha', 'set', {
      'task_id': 'dbid_999',
      'code': '1234',
    });
    expect((missing.json['error'] as Map)['code'], 117);
  });

  test('㉒ Captcha:download 回真图片字节（PNG 魔数 ⇒ 不是 JSON 错误页）', () {
    final id = create('https://example.com/need-captcha.bin');
    final raw = backend.handleRaw('entry.cgi', {
      'api': 'SYNO.DownloadStation2.Captcha',
      'method': 'download',
      'version': '2',
      '_sid': sid,
      'task_id': id,
      't': '1',
    });
    expect(raw.ok, isTrue, reason: raw.note);
    expect(raw.contentType, 'image/png');
    expect(raw.bytes.length, greaterThan(8));
    // PNG 魔数：89 50 4E 47 0D 0A 1A 0A
    expect(raw.bytes.take(8).toList(), [137, 80, 78, 71, 13, 10, 26, 10]);

    // 反向：缺 task_id ⇒ 120；任务不存在 ⇒ 404（真机是 HTML 错误页那一档）
    final noId = backend.handleRaw('entry.cgi', {
      'api': 'SYNO.DownloadStation2.Captcha',
      'method': 'download',
      'version': '2',
      '_sid': sid,
    });
    expect(noId.ok, isFalse);
    expect(noId.errorCode, 120);
    final gone = backend.handleRaw('entry.cgi', {
      'api': 'SYNO.DownloadStation2.Captcha',
      'method': 'download',
      'version': '2',
      '_sid': sid,
      'task_id': 'dbid_999',
    });
    expect(gone.ok, isFalse);
    expect(gone.errorCode, 404);
  });
}
