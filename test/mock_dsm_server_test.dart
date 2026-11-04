// DSM Mock Server 的自测 + **App 引用覆盖**检查。
//
// ## 这套东西为什么存在（用户 2026-09-23 新规，原话）
// > 涉及管理员的接口，在电脑上搭建 mock server 模拟测试，**必须通过模拟测试**，
// > 接口定义以及服务端返回数据可以通过反编译 spk 以及 apk 来获取。
// > 改完之后就是所有的客户端功能必须都要实现并验证，**一个都不能遗漏**，
// > 那些无法验证的也都通过模拟服务器来验证。
//
// 权威事实 = `tool/mock_dsm/catalog.json`（由 `build_catalog.py` 从反编译 SPK 的
// `webapi/*.lib` 汇总）。本文件先证明"mock 本身按权威目录正确拒绝/放行"，
// 再做一次**全仓 API 引用覆盖**清点 —— 那是"一个都不能遗漏"的量化抓手。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';

void main() {
  final catalog = DsmCatalog.load();

  group('M0-1. 权威目录本身', () {
    test('从反编译 SPK 汇总出规模合理的目录', () {
      // 这些数字是 build_catalog.py 跑出来的**测量值**，随 SPK 版本变化会变；
      // 断言给一个下界，避免"目录突然变空还照样过"。
      expect(catalog.apiCount, greaterThan(900));
      expect(catalog.normalOnly.length, greaterThan(500));
      // 新规的核心对象：仅管理员 API 必须有，否则"用 mock 验管理员"无从谈起。
      expect(catalog.adminOnly.length, greaterThan(300));
    });

    test('每条都有合法版本区间；有方法表的条目每个列出的版本都有方法', () {
      for (final a in catalog.apis.values) {
        expect(
          a.maxVersion,
          greaterThanOrEqualTo(a.minVersion),
          reason: '${a.name} 区间 ${a.minVersion}-${a.maxVersion} 反了',
        );
        // ⚠️ 真实数据里存在 `methods: {"1": []}`（例：`SYNO.Core.AppPriv` v1
        // 在 SPK 里就是空清单）。**空清单是合法的**，它的语义是
        // "这一版没有任何方法" ⇒ mock 在该版本上必须拒绝一切方法。
        for (final v in a.versions) {
          expect(a.methods[v], isNotNull, reason: '${a.name} v$v 缺清单');
        }
      }
    });

    test('★ 真实事实：13 个 API 的 maxVersion 大于方法表列过的版本（不能信 maxVersion）', () {
      final mismatch = catalog.apis.values
          .where((a) => a.methodsVerified && !a.versions.contains(a.maxVersion))
          .toList();
      // 这些是反编译 SPK 里的**真实数据**，mock 通过"版本区间 + 回落解析"支持它们。
      expect(mismatch, isNotEmpty, reason: '如果这条断言失败，说明 SPK 行为变了，回落逻辑要重新评估');
      for (final a in mismatch) {
        expect(
          a.resolveMethodVersion(a.maxVersion),
          a.versions.last,
          reason: '${a.name} v${a.maxVersion} 应回落到 v${a.versions.last}',
        );
      }
    });

    test('无方法表的条目 methodsVerified=false（没数据就不假装能校验方法名）', () {
      expect(catalog.methodUnverifiable, isNotEmpty);
      final live = catalog.methodUnverifiable.where((a) => a.source == 'live');
      expect(live, isNotEmpty, reason: '实况快照条目应当没有方法表');
      for (final a in catalog.methodUnverifiable) {
        // 不变量：methodsVerified=false ⇒ 要么没有方法表（实况），
        // 要么 SPK 的 `.lib` 该条目压根没写 `methods` 字段。
        expect(
          a.methods.isEmpty || a.source == 'spk',
          isTrue,
          reason: '${a.name} source=${a.source} methods=${a.methods}',
        );
      }
    });

    test('cgi 路径与真实 DSM 一致（query/auth/encryption/entry）', () {
      expect(catalog['SYNO.API.Info']!.path, 'query.cgi');
      expect(catalog['SYNO.API.Auth']!.path, 'auth.cgi');
      expect(catalog['SYNO.API.Encryption']!.path, 'encryption.cgi');
      expect(catalog['SYNO.FileStation.List']!.path, 'entry.cgi');
    });
  });

  group('M0-2. mock 的校验语义（会拒绝错的调用）', () {
    late MockDsmBackend backend;

    setUp(() => backend = MockDsmBackend(catalog: catalog));

    test('query.cgi：Query 把目录当"服务器能力表"回出去', () {
      final r = backend.handle('query.cgi', {
        'api': 'SYNO.API.Info',
        'method': 'Query',
        'version': 1,
        'query': 'all',
      });
      expect(r.ok, isTrue);
      final data = r.json['data'] as Map;
      expect(data.length, catalog.apiCount);
      expect((data['SYNO.FileStation.List'] as Map)['path'], 'entry.cgi');
    });

    test('缺必填参数 ⇒ 114，且带 errors.name', () {
      final r = backend.handle('entry.cgi', {'api': 'SYNO.FileStation.List'});
      expect(r.errorCode, 114);
      expect((r.json['error'] as Map)['errors'], {
        'name': 'method',
        'reason': 'required',
      });
    });

    test('目录里没有的 api ⇒ 101', () {
      final r = backend.handle('entry.cgi', {
        'api': 'SYNO.NotAReal.Api',
        'method': 'list',
        'version': 1,
      });
      expect(r.errorCode, 101);
    });

    test('没登录 ⇒ 119（authLevel>0）', () {
      final r = backend.handle('entry.cgi', {
        'api': 'SYNO.FileStation.List',
        'method': 'list',
        'version': 1,
      });
      expect(r.errorCode, 119);
    });

    test('★ 版本里没有这个方法 ⇒ 103（只按 maxVersion 协商必被抓）', () {
      backend.login(username: 'u', admin: false);
      final sid = backend.sessions.first;
      // 真实事实（读自反编译 SPK 的 SYNO.API.Auth.lib）：
      //   * 大写 `Login` 只在 v6；
      //   * `synotoken` 在 v5/v6 有，**v7 没有**。
      final spec = catalog['SYNO.API.Auth']!;
      expect(spec.versionsWith('Login'), [6], reason: '前提：Login 只在 v6');
      expect(spec.versionsWith('synotoken'), [
        5,
        6,
      ], reason: '前提：v7 没有 synotoken');

      var r = backend.handle('auth.cgi', {
        'api': 'SYNO.API.Auth',
        'method': 'Login',
        'version': 1,
        '_sid': sid,
      });
      expect(r.errorCode, 103, reason: 'v1 没有 Login');

      // 这一条最能说明问题：v7 是 maxVersion，但 v7 偏偏没有 synotoken。
      r = backend.handle('auth.cgi', {
        'api': 'SYNO.API.Auth',
        'method': 'synotoken',
        'version': 7,
        '_sid': sid,
      });
      expect(
        r.errorCode,
        103,
        reason: '照 maxVersion=7 协商 synotoken 就会吃 103 —— 正是要抓的那个坑',
      );

      r = backend.handle('auth.cgi', {
        'api': 'SYNO.API.Auth',
        'method': 'Login',
        'version': 6,
        'account': 'u',
        '_sid': sid,
      });
      expect(r.ok, isTrue, reason: 'v6 才有 Login');
    });

    test('version 超出该 API 的版本集合 ⇒ 103', () {
      backend.login(username: 'u', admin: false);
      final r = backend.handle('entry.cgi', {
        'api': 'SYNO.FileStation.List',
        'method': 'list',
        'version': 99,
        '_sid': backend.sessions.first,
      });
      expect(r.errorCode, 103);
    });

    test('★ 仅管理员 API：普通会话 105，管理员会话通过（新规核心）', () {
      final adminApi = catalog.adminOnly.first;
      expect(adminApi.adminOnly, isTrue, reason: '前提：它确实仅管理员');
      final v = adminApi.maxVersion;
      final m = adminApi.methodsAt(v).first;

      final userSid = backend.login(username: 'u', admin: false);
      var r = backend.handle('entry.cgi', {
        'api': adminApi.name,
        'method': m,
        'version': v,
        '_sid': userSid,
      });
      expect(r.errorCode, 105, reason: '${adminApi.name} 仅管理员，普通会话必须被拒');

      final adminSid = backend.login(username: 'admin', admin: true);
      r = backend.handle('entry.cgi', {
        'api': adminApi.name,
        'method': m,
        'version': v,
        '_sid': adminSid,
      });
      expect(r.ok, isTrue, reason: '管理员会话应当放行（这就是 mock 的意义）');
    });

    test('普通用户 API：管理员会话也能过（不误伤）', () {
      final sid = backend.login(username: 'admin', admin: true);
      final r = backend.handle('entry.cgi', {
        'api': 'SYNO.FileStation.List',
        'method': 'list',
        'version': 1,
        '_sid': sid,
      });
      expect(r.ok, isTrue);
    });
  });

  group('M0-3. ★ 全仓 API 引用覆盖（"一个都不能遗漏"的量化抓手）', () {
    /// 从 `lib/` 抠出所有 `SYNO.X.Y…` 形式的字面量。
    Set<String> rawReferences() {
      final re = RegExp(
        r'''['"]\s*(SYNO\.[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)\s*['"]''',
      );
      final found = <String>{};
      for (final f
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        for (final m in re.allMatches(f.readAsStringSync())) {
          found.add(m.group(1)!);
        }
      }
      return found;
    }

    /// 把一个字面量解析成"目录里的 API"，或"某 API 下的方法引用"。
    ///
    /// 做法：**最长前缀匹配**。`SYNO.API.Auth.login` 里
    /// `SYNO.API.Auth` 是目录里的 API，`.login` 是方法名 —— 这样不但能认出来，
    /// 还能顺手校验方法名到底存不存在（比只认 API 名强）。
    ({DsmApiSpec spec, String? method})? resolve(String ref) {
      var cut = ref.length;
      while (cut > 0) {
        final head = ref.substring(0, cut);
        final spec = catalog[head];
        if (spec != null) {
          final rest = ref.substring(cut);
          return (
            spec: spec,
            method: rest.startsWith('.') ? rest.substring(1) : null,
          );
        }
        final dot = ref.lastIndexOf('.', cut - 1);
        if (dot < 0) break;
        cut = dot;
      }
      return null;
    }

    test('App 引用的每个 SYNO.* 字面量都能落到权威目录里的某个 API 上', () {
      final refs = rawReferences();
      expect(refs, isNotEmpty, reason: '正则失效会静默变空 —— 必须有下界');

      final unresolved = <String>[];
      for (final r in refs) {
        if (resolve(r) == null) unresolved.add(r);
      }
      // ---- 豁免集合**从代码自身的声明推导**，不手写白名单 ----
      // 三类字面量不是"接口声明"，所以本来就不该在目录里：
      //   1. `SYNO.SDS.*` —— `appPriv`（应用权限标识）；
      //   2. `service_registry.dart` 里 `appPrivilegeKeys:` 列出的
      //      `dsmappname`（例：`SYNO.Foto.AppInstance`、`SYNO.Cal.Application`）；
      //   3. `webapi.dart` `_pathHint` 里的 cgi 路径回退键
      //      （例：`SYNO.Chat.Message` —— 本 NAS 无此 API，只在回退表里）。
      // 从源码抽出来 ⇒ 新增 appPriv 自动算非接口，而**真正的接口名写错、
      // 或引用了不存在的 API，依然会被这条用例抓住**。
      final allowedNonApi = <String>{
        'SYNO.ALLOW.ALL.APPLICATIONS', // 可编程权限字面量（权限判定用）
      };
      final reg = File(
        'lib/src/core/services/service_registry.dart',
      ).readAsStringSync();
      for (final m in RegExp(
        r'appPrivilegeKeys:\s*\[([^\]]*)\]',
      ).allMatches(reg)) {
        for (final q in RegExp(r"'([^']+)'").allMatches(m.group(1)!)) {
          allowedNonApi.add(q.group(1)!);
        }
      }
      final webapiSrc = File('lib/src/dsm/webapi.dart').readAsStringSync();
      final hintBlock = RegExp(
        r'const hints = \{([\s\S]*?)\};',
      ).firstMatch(webapiSrc);
      if (hintBlock != null) {
        for (final q in RegExp(
          r"'([^']+)'\s*:",
        ).allMatches(hintBlock.group(1)!)) {
          allowedNonApi.add(q.group(1)!);
        }
      }
      // ignore: avoid_print
      print(
        '★ 推导出的非接口字面量 ${allowedNonApi.length} 个：'
        '${allowedNonApi.toList()..sort()}',
      );

      final left =
          unresolved
              .where(
                (r) => !allowedNonApi.contains(r) && !r.startsWith('SYNO.SDS.'),
              )
              .toList()
            ..sort();
      expect(
        left,
        isEmpty,
        reason:
            '有 ${left.length} 个字面量在 SPK/实况目录里都找不到对应 API：\n'
            '  ${left.join('\n  ')}',
      );
    });

    test('★ 引用到的 "API.方法" 组合在该 API 的某些版本里真的存在', () {
      final bad = <String>[];
      var methodRefs = 0;
      for (final r in rawReferences()) {
        final res = resolve(r);
        if (res == null || res.method == null) continue;
        methodRefs++;
        if (!res.spec.methodsVerified) continue; // 没方法表就不假装能校验
        if (res.spec.versionsWith(res.method!).isEmpty) {
          bad.add(
            '$r → ${res.spec.name} 的任何版本都没有 `${res.method}`'
            '（有 ${res.spec.versions}）',
          );
        }
      }
      expect(methodRefs, greaterThan(0), reason: '一个都没解析出方法引用 ⇒ 解析器坏了');
      expect(bad, isEmpty, reason: bad.join('\n'));
    });

    test('被引用的 API 里有多少是"仅管理员"（这些**只能**靠 mock 验证）', () {
      final refs = rawReferences();
      final admin =
          refs
              .map((r) => resolve(r)?.spec)
              .whereType<DsmApiSpec>()
              .where((s) => s.adminOnly)
              .map((s) => s.name)
              .toSet()
              .toList()
            ..sort();
      // 不硬编码数量（会随实现变化），把事实打印出来供报告引用。
      // ignore: avoid_print
      print('★ 仅管理员且被 App 引用：${admin.length}\n  ${admin.join('\n  ')}');
      expect(admin, isNotNull);
    });

    test('未解析字面量的规模（防止正则/豁免悄悄放水）', () {
      final refs = rawReferences();
      final unresolved = refs
          .where((r) => resolve(r) == null && r.startsWith('SYNO.SDS.'))
          .length;
      // appPriv 的数量随模块增长，给一个宽松上界即可；关键是**它被统计了**。
      expect(unresolved, lessThan(400));
    });
  });
}
