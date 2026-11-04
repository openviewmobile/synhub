// ★ 第 260 轮：**"我们调的每个只读方法，真 NAS 上到底存不存在？"** —— 全模块只读扫描。
//
// 为什么需要它（AGENTS §3 的版本陷阱）：
//   Synology 的方法**分散在互不包含的版本里**（`archive` 只在某几个版本有），
//   照 `maxVersion` 协商会吃 `103 方法不存在`。本仓已经因为这类问题踩过两次
//   （`Core.Service:get` 在 v2 不在 v1；`Core.MyDSCenter:query` 在 v2 不在 v1）。
//
// 判据（**方法存在性不许靠扫描猜**，但可以用 103 当否证）：
//   对 `(api, method, version)` 逐版本发一次请求，**只有 `103` 才代表"该版本没有这个方法"**；
//   其余响应（`0` 成功 / `105` 无权限 / `120` 缺参数 / `119` ……）都说明**方法存在**。
//   ⇒ 这样就不需要为每个方法准备合法参数。
//
// 输出：
//   * ❌ **一个版本都没有**该方法的 `(api, method)` —— 这是**硬缺陷**（我方在调空气）；
//   * ⚠️ 方法存在但**最早版本 ≠ 我们客户端用的版本** —— 潜在 `103` 风险，人工核对；
//   * ✔ 正常（记录存在版本区间）。
//
// 跑法（只读：`query` / `list` / `get`，无任何变更动词）：
//   set -a && . /tmp/nas_cred.env && set +a
//   SYNO_NAS_URL=https://nas.example.com:5001 SYNO_ACCOUNT="$NAS_ACCOUNT" \
//     SYNO_PASSWORD="$NAS_PASSWORD" dart run tool/read_method_sweep.dart
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

/// 只读方法名白名单（判定口径：只要不以写动词开头，就算"读"）。
const _writeVerbs = {
  'set', 'delete', 'create', 'update', 'add', 'remove', 'upload', 'write',
  'save', 'rename', 'move', 'copy', 'edit', 'make', 'publish', 'start',
  'stop', 'pause', 'resume', 'cancel', 'clear', 'apply', 'send', 'post',
  'put', 'share', 'mount', 'unmount', 'encrypt', 'decrypt', 'logout',
  'login', 'auth', 'install', 'uninstall', 'enable', 'disable', 'reset',
  'restore', 'backup', 'clean', 'purge', 'kill', 'run', 'exec', 'commit',
  'import', 'export', 'sync', 'tag', 'untag', 'check', 'verify', 'test',
};

bool _isRead(String method) {
  final m = method.toLowerCase();
  for (final v in _writeVerbs) {
    if (m == v || m.startsWith('${v}_') || m.startsWith(v)) return false;
  }
  return true;
}

Future<void> main() async {
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
  final apis = await api.discover();
  print('✔ 登录成功；API 注册表 ${apis.length} 个');

  // 待扫的 (api, method) —— 由 `lib/src/data/**` 里真实调用点抽出（只读子集）。
  final targets = <List<String>>[];
  final src = Directory('lib/src/data');
  // ★ 只认真正的调用点。早先还用了 `'SYNO.X'\s*,\s*'method'` 这种宽正则，
  // 结果把 **map 字面量**（`'SYNO.Contacts.Addressbook': 'version'`）也扫进来，
  // 报了一个假的"方法不存在"—— 判缺陷前先确认它是不是真的调用点。
  final re1 = RegExp(
      r"(?:api\.)?call\(\s*'([A-Za-z0-9_.]+)'\s*,\s*\n?\s*'([A-Za-z0-9_]+)'");
  for (final f in src.listSync()) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    final s = f.readAsStringSync();
    for (final m in re1.allMatches(s)) {
      final a = m.group(1)!;
      final meth = m.group(2)!;
      if (!a.startsWith('SYNO.')) continue;
      if (!_isRead(meth)) continue;
      targets.add([a, meth]);
    }
  }
  // 去重
  final seen = <String>{};
  final list = <List<String>>[];
  for (final t in targets) {
    if (seen.add('${t[0]}|${t[1]}')) list.add(t);
  }
  print('待扫只读 (api,method) 共 ${list.length} 条\n');

  var noVersion = 0, exists = 0, apiMissing = 0, inconclusiveCount = 0;
  final findings = <Map<String, Object?>>[];
  for (final t in list) {
    final name = t[0], method = t[1];
    final e = apis[name];
    if (e == null) {
      apiMissing++;
      findings.add({'api': name, 'method': method, 'verdict': 'api-missing'});
      print('❌ $name/$method —— API 未注册（我方在调空气）');
      continue;
    }
    final okVersions = <int>[];
    final inconclusive = <String>{};
    String? lastCode;
    for (var v = e.maxVersion; v >= e.minVersion; v--) {
      try {
        await api.call(name, method, preferredVersion: v, params: const {});
        okVersions.add(v);
      } on DsmApiException catch (err) {
        lastCode = '${err.code}';
        if (err.code != 103) okVersions.add(v); // 存在（105/120/119/…）
      } on DsmTransportException catch (err) {
        // ★ 传输层失败（HTTP 400 / 非 JSON）**不能**当成"方法不存在"：
        //   `Files:download` 这类**下载端点**要参数、回的是字节，
        //   空参调用本来就会 400。⇒ 记为 **inconclusive**，别报假缺陷。
        lastCode = 'transport: ${err.message}';
        inconclusive.add('$v');
      } on Object catch (err) {
        final t = '$err'; lastCode = t.length > 60 ? t.substring(0, 60) : t;
        inconclusive.add('$v');
      }
    }
    if (okVersions.isEmpty && inconclusive.isNotEmpty) {
      inconclusiveCount++;
      findings.add({
        'api': name, 'method': method, 'verdict': 'inconclusive',
        'declared': '${e.minVersion}..${e.maxVersion}', 'note': lastCode,
      });
      print('❓ $name/$method —— 判不了（传输层，不是 103）：$lastCode');
      continue;
    }
    if (okVersions.isEmpty) {
      noVersion++;
      findings.add({
        'api': name, 'method': method, 'verdict': 'no-version',
        'declared': '${e.minVersion}..${e.maxVersion}', 'lastCode': lastCode,
      });
      print('❌ $name/$method —— 声明 ${e.minVersion}..${e.maxVersion} 全都不认'
          '${lastCode == null ? '' : '（末次 $lastCode）'}');
    } else {
      exists++;
      final min = okVersions.reduce((a, b) => a < b ? a : b);
      final max = okVersions.reduce((a, b) => a > b ? a : b);
      findings.add({
        'api': name, 'method': method, 'verdict': 'ok',
        'existsMin': min, 'existsMax': max,
        'declared': '${e.minVersion}..${e.maxVersion}',
      });
      if (min != e.minVersion) {
        print('⚠️ $name/$method —— 方法只在 v$min..v$max 有'
            '（API 声明 ${e.minVersion}..${e.maxVersion}）⇒ 协商必须落在区间内');
      }
    }
  }

  print('\n===== 汇总 =====');
  print('API 未注册（硬缺陷）: $apiMissing');
  print('方法在所有声明版本都不存在（硬缺陷）: $noVersion');
  print('存在: $exists');
  print('判不了（传输层，需人工看）: $inconclusiveCount');
  final out = File('/tmp/read_method_sweep.json');
  out.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'nas': Platform.environment['SYNO_NAS_URL'],
      'scanned': list.length,
      'apiMissing': apiMissing,
      'noVersion': noVersion,
      'exists': exists,
      'inconclusive': inconclusiveCount,
      'findings': findings,
    }),
  );
  print('明细 → ${out.path}');
  await api.logout();
}
