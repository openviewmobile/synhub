// ★ 第 260 轮：**模板缩略图/预览**这条路的真机只读取证。
//
// 用户 2026-09-26 要求：「office 模版……做成网格展示并显示缩略图并提供预览功能，
// 具体可以参考 spk 里面的实现」。
//
// 官方 SPK（Office 3.8.0-22711）里取到的两处硬事实：
//   1. `webapi/SYNO.Office.lib`：**`SYNO.Office.Template.Thumb` v1 = `get`**
//      （`allowDownload: true` ⇒ 回的是**图片字节**，不是 JSON）；
//      DB schema（`scripts/create_template.sql`）里 `template` 表有
//      `object_id / publish_version / thumb JSON / ntype / sort_order / system`，
//      `template_link` 表有 `(id, object_id, category, ntype)` —— category 就是分组。
//   2. 官方 Web 前端的取图 URL（`ui/dist/ui.doc.js` 的 `getThumbImg`）：
//      `api=SYNO.Office.Template.Thumb&version=1&method=get
//        &object_id=<object_id>&ver=<system ? 应用版本 : publish_version>&retina=<bool>`
//
// 本探针把这两条**在真 NAS 上钉死**（只读：`list` / `get`，无任何变更动词）：
//   * `Template:list` 的真实条目字段（object_id / ntype / publish_version / system …）
//   * `Template.Thumb:get` 的 HTTP 状态、Content-Type、magic、字节数（1x 与 2x 各取一次）
//   * 取回的图落到 /tmp/office_thumb_probe/ 供人眼核对
//
// 跑法：
//   source /tmp/nas_cred.env && SYNO_NAS_URL=https://nas.example.com:5001 \
//     SYNO_ACCOUNT=$NAS_ACCOUNT SYNO_PASSWORD=$NAS_PASSWORD \
//     dart run tool/office_template_thumb_probe.dart
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<DsmWebApi> _login() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'FileStation',
  );
  return api;
}

/// 给一个 API 协商出可用版本（取 **最早** 的候选，见 AGENTS §3 的版本陷阱）。
int? _version(Map<String, DsmApiEntry> apis, String name) {
  final e = apis[name];
  if (e == null) {
    print('  API.Info $name → ✘ 未注册');
    return null;
  }
  print('  API.Info $name → min=${e.minVersion} max=${e.maxVersion}');
  return e.minVersion;
}

String _magic(List<int> b) {
  if (b.length < 8) return '<太短>';
  if (b[0] == 0x89 && b[1] == 0x50) return 'PNG';
  if (b[0] == 0xFF && b[1] == 0xD8) return 'JPEG';
  if (b[0] == 0x47 && b[1] == 0x49) return 'GIF';
  if (b[0] == 0x42 && b[1] == 0x4D) return 'BMP';
  final head = String.fromCharCodes(b.take(64)).trimLeft();
  if (head.startsWith('<svg') || head.startsWith('<?xml')) return 'SVG/XML';
  if (head.startsWith('{') || head.startsWith('[')) return 'JSON(疑似错误回包)';
  return '未知(${b.take(6).map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ')})';
}

Future<void> main() async {
  final out = Directory('/tmp/office_thumb_probe')..createSync(recursive: true);
  final api = await _login();
  print('✔ 登录成功');
  final apis = await api.discover();

  // ---- ① Template:list 的真实条目 ----
  print('\n=== ① SYNO.Office.Template:list ===');
  final ver = _version(apis, 'SYNO.Office.Template');
  final data = await api.call(
    'SYNO.Office.Template',
    'list',
    params: const {},
    preferredVersion: ver ?? 1,
  );
  final map = data;
  // ★ 真机回包顶层是 `{items, offset, total}`（不是 `list`）—— 第 260 轮实测。
  final list = (map['items'] is List) ? map['items'] as List : const [];
  print(
    '条目数=${list.length} offset=${map['offset']} total=${map['total']}；'
    '顶层键=${map.keys.toList()}',
  );
  for (final it in list.take(6)) {
    if (it is Map) {
      print('  · ${jsonEncode(it)}');
    }
  }
  // 字段覆盖率（决定我们的网格能不能拿到 object_id / ntype / publish_version）
  final keys = <String, int>{};
  for (final it in list) {
    if (it is Map) {
      for (final k in it.keys) {
        keys['$k'] = (keys['$k'] ?? 0) + 1;
      }
    }
  }
  print('字段覆盖：${keys.entries.map((e) => '${e.key}×${e.value}').join(', ')}');

  // ---- ② Template.Thumb:get 取图 ----
  print('\n=== ② SYNO.Office.Template.Thumb:get ===');
  final thumbVer = _version(apis, 'SYNO.Office.Template.Thumb');
  var got = 0;
  for (final it in list.take(6)) {
    if (it is! Map) continue;
    final objectId = '${it['object_id'] ?? ''}';
    final ntype = '${it['ntype'] ?? ''}';
    final system = it['system'] == true;
    // 官方：system 用应用版本，用户模板用 publish_version
    final verParam = system
        ? '${it['version'] ?? it['publish_version'] ?? ''}'
        : '${it['publish_version'] ?? ''}';
    for (final retina in [false, true]) {
      final url = api.authenticatedUrl(
        api.apiPath('SYNO.Office.Template.Thumb'),
        {
          'api': 'SYNO.Office.Template.Thumb',
          'version': '${thumbVer ?? 1}',
          'method': 'get',
          'object_id': objectId,
          if (verParam.isNotEmpty) 'ver': verParam,
          'retina': '$retina',
        },
      );
      try {
        final bytes = await api.getBytes(url);
        final ct = '?';
        final name =
            '${ntype}_${objectId}_${retina ? '2x' : '1x'}.${_magic(bytes).toLowerCase().replaceAll(RegExp(r'[^a-z]'), '')}';
        if (bytes.isNotEmpty) {
          File('${out.path}/$name').writeAsBytesSync(bytes);
        }
        print(
          '  ✔ $ntype object_id=$objectId ver=$verParam retina=$retina → '
          '${bytes.length}B ct=$ct magic=${_magic(bytes)} → $name',
        );
        got++;
      } catch (e) {
        print(
          '  ✘ $ntype object_id=$objectId ver=$verParam retina=$retina → $e',
        );
      }
    }
  }
  // ---- ④ Template:get 的 `link_id` 能不能喂给 Snapshot:get（真内容预览？） ----
  print('\n=== ④ Template.link_id → Office.Snapshot:get（真内容预览可行性） ===');
  final perType = <String, Map>{};
  for (final it in list) {
    if (it is Map && !perType.containsKey('${it['ntype']}')) {
      perType['${it['ntype']}'] = Map<String, dynamic>.from(it);
    }
  }
  for (final e in perType.entries) {
    final it = e.value;
    final oid = '${it['object_id']}';
    final v = _version(apis, 'SYNO.Office.Template');
    Map<String, dynamic> meta = const {};
    try {
      final d = await api.call(
        'SYNO.Office.Template',
        'get',
        params: {'object_id': oid},
        preferredVersion: v ?? 1,
      );
      meta = Map<String, dynamic>.from(d);
    } catch (err) {
      print('  Template:get $oid ✘ $err');
      continue;
    }
    print(
      '  · ${e.key} $oid thumb=${jsonEncode(meta['thumb'])} '
      'link_id=${meta['link_id']} ver=${meta['ver']} sort=${meta['sort_order']}',
    );
    final linkId = '${meta['link_id'] ?? ''}';
    if (linkId.isEmpty) continue;
    for (final params in [
      {'link_id': linkId, 'password': ''},
      {'link_id': linkId, 'password': '', 'object_id': oid},
    ]) {
      try {
        final d = await api.call(
          'SYNO.Office.Snapshot',
          'get',
          params: params,
          preferredVersion: 4,
        );
        final enc = jsonEncode(d);
        final keys = d.keys.toList();
        print(
          '    ✔ Snapshot:get $params → ${enc.length} 字符；键=$keys',
        );
        print('       ntype=${d['ntype']} object_id=${d['object_id']} '
            'file=${jsonEncode(d['file']).substring(0, 80)}');
        final content = d['content'];
        if (content is Map) {
          print('       content 顶层键=${content.keys.toList()}');
        } else if (content is List) {
          print('       content 是 List，长度=${content.length}');
        }
      } catch (err) {
        print('    ✘ Snapshot:get $params → $err');
      }
    }
  }

  print('\n成功取图 $got 张，落在 ${out.path}');

  // ---- ③ 模板**内容**能不能取（决定"预览"是只放缩略图还是能真渲染） ----
  print('\n=== ③ Template:get / Snapshot:get（预览可行性） ===');
  final docTpl = list.firstWhere(
    (e) => e is Map && e['ntype'] == 'doc',
    orElse: () => list.isEmpty ? const {} : list.first,
  );
  if (docTpl is Map) {
    final oid = '${docTpl['object_id']}';
    final ntype = '${docTpl['ntype']}';
    for (final call in [
      ['SYNO.Office.Template', 'get', {'object_id': oid}],
      ['SYNO.Office.Template', 'get', {'object_id': oid, 'ver': docTpl['ver']}],
      if (ntype == 'presentation')
        ['SYNO.Office.Presentation.Snapshot', 'get', {'object_id': oid}],
      if (ntype == 'doc') ['SYNO.Office.Doc.Snapshot', 'get', {'object_id': oid}],
      if (ntype == 'sheet')
        ['SYNO.Office.Sheet.Snapshot', 'get', {'object_id': oid}],
      ['SYNO.Office.Snapshot', 'get', {'object_id': oid}],
    ]) {
      final name = call[0] as String;
      final method = call[1] as String;
      final params = call[2] as Map<String, dynamic>;
      final v = _version(apis, name);
      if (v == null) {
        print('  ⏭ $name/$method 未注册，跳过');
        continue;
      }
      try {
        final d = await api.call(
          name,
          method,
          params: params,
          preferredVersion: v,
        );
        final enc = jsonEncode(d);
        // 键清单 + 前 300 字符（别把整份文档灌进日志）
        final keys = d.keys.toList();
        print('  ✔ $name/$method $params → ${enc.length} 字符；键=$keys');
        for (final k in d.keys.take(12)) {
          final val = jsonEncode(d[k]);
          print('      $k = ${val.length > 150 ? '${val.substring(0, 150)}…' : val}');
        }
      } catch (e) {
        print('  ✘ $name/$method $params → $e');
      }
    }
  }
  await api.logout();
}
