// `SYNO.FileStation.Compress / start` 的**取值表裁决**（M21，审计行 141）。
//
// ## 为什么这组用例存在
// 我方原先的 `level` 第三档是 `moderate` —— 它**不是观测到的线上值**，
// 而是从服务端 `.so` 里一个**没有名字的 flag**（`-mx6`）反推出来的臆测。
// `mode` 的默认档 `add` 同理（服务端 `.so` 里默认档**没有名字**）。
//
// 这组用例把**三个权威源各自的原文**钉进断言，这样将来任何一方被改坏、
// 或者有人又想"反推"，都会红。
//
// ## 三个源
// 1. **官方 APK** `dsfile_out/res/values/arrays.xml`（客户端发什么）
// 2. **服务端 `.so`** `SYNO.FileStation.Compress.so`（服务端认什么）
// 3. 本仓枚举（我们发什么）
//
// ⚠️ 断言里**不读 APK/.so 文件**（那需要反编译产物在位上，CI 上没有）。
// 这里是把这些源**已经核对过的结论**写成常量，并注明出处；
// 源文件本身留在 `docs/evidence-r18/` 与 `/tmp/spk` 的解包产物里。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/file_sheets.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

void main() {
  group('C1. 取值表：以官方 APK 的 arrays.xml 为准', () {
    test('★ level 是 store/fastest/**normal**/best —— 第三档不是 moderate', () {
      final values = CompressLevel.values.map((e) => e.value).toList();
      expect(values, ['store', 'fastest', 'normal', 'best']);
      // 反证：旧臆测值必须已经不在表里（防"改回去了"）
      expect(values, isNot(contains('moderate')));
    });

    test('★ mode 是 replace/update/freshen/**synchronize**', () {
      final values = CompressMode.values.map((e) => e.value).toList();
      expect(values, ['replace', 'update', 'freshen', 'synchronize']);
      // 旧臆测值必须已经不在表里
      expect(values, isNot(contains('add')));
      // ★ 官方 APK 的同步档是拼写错误的 `synchroize`（漏了 n）。
      // 服务端 `.so` 只认 `synchronize` ⇒ **本仓不照抄那个错**。
      expect(
        values,
        isNot(contains('synchroize')),
        reason: '官方 APK 这里拼错了；照抄官方 = 照抄一个 bug',
      );
    });

    test('format 只认 zip / 7z', () {
      expect(CompressFormat.values.map((e) => e.value).toList(), ['zip', '7z']);
    });

    test('★ 四个 mode 档位都还有对应译文键（改值不能把 label 弄丢）', () {
      for (final m in CompressMode.values) {
        expect(m.key, isNotEmpty);
        expect(m.zh, isNotEmpty);
      }
      for (final l in CompressLevel.values) {
        expect(l.key, isNotEmpty);
        expect(l.zh, isNotEmpty);
      }
    });
  });

  group('C2. 真实 FileStationApi × Mock Server', () {
    late DsmCatalog catalog;
    late MockDsmBackend backend;
    late MockDsmTransport transport;
    late FileStationApi fs;

    setUp(() async {
      catalog = DsmCatalog.load();
      backend = MockDsmBackend(catalog: catalog);
      backend.login(username: 'u', admin: false);
      transport = MockDsmTransport(backend);
      final web = DsmWebApi(transport);
      await web.discover();
      await web.login(account: 'u', password: 'x');
      fs = FileStationApi(web);
    });

    test('startCompress 默认发 level=normal + mode=replace，组合合法', () async {
      await fs.startCompress(
        paths: const ['/home/a.txt'],
        destFilePath: '/home/a.zip',
      );
      final r = backend.requests.lastWhere(
        (r) => r.params['api'] == 'SYNO.FileStation.Compress',
      );
      expect(r.params['method'], 'start');
      expect(r.params['level'], 'normal');
      expect(r.params['mode'], 'replace');
      expect(r.params['format'], 'zip');
      expect(
        catalog['SYNO.FileStation.Compress']!.versionsWith('start'),
        isNotEmpty,
      );
      expect(transport.last!.errorCode, isNull, reason: '组合在权威表里合法');
    });

    test('★ `mode` **每次都发**（缺了服务端 101）', () async {
      await fs.startCompress(
        paths: const ['/home/a.txt'],
        destFilePath: '/home/a.zip',
      );
      final r = backend.requests.lastWhere(
        (r) => r.params['api'] == 'SYNO.FileStation.Compress',
      );
      expect(r.params.containsKey('mode'), isTrue);
      expect(r.params['mode'], isNotEmpty);
    });

    test('同步档发的是服务端认识的 synchronize（不是官方的错拼）', () async {
      await fs.startCompress(
        paths: const ['/home/a.txt'],
        destFilePath: '/home/a.zip',
        mode: CompressMode.synchronize.value,
      );
      final r = backend.requests.lastWhere(
        (r) => r.params['api'] == 'SYNO.FileStation.Compress',
      );
      expect(r.params['mode'], 'synchronize');
    });
  });

  group('C3. 接线守卫：UI 真能选到新取值', () {
    test('压缩面板的下拉真的由枚举生成（不是写死 zip/normal）', () {
      final src = _read('lib/src/features/files/file_sheets.dart');
      expect(src, contains('for (final m in CompressMode.values)'));
      expect(src, contains('for (final l in CompressLevel.values)'));
      expect(
        src,
        contains('CompressMode _mode = CompressMode.replace;'),
        reason: '默认档必须是 replace',
      );
      expect(
        src,
        contains('CompressLevel _level = CompressLevel.normal;'),
        reason: '默认档必须是 normal',
      );
    });

    test('API 默认值也同步改了（防"UI 改了、默认值没改")', () {
      final src = _read('lib/src/data/filestation_api.dart');
      expect(src, contains("String level = 'normal',"));
      expect(src, contains("String mode = 'replace',"));
      expect(src, isNot(contains("String level = 'moderate',")));
      expect(src, isNot(contains("String mode = 'add',")));
    });
  });
}

String _read(String p) => File(p).readAsStringSync();
