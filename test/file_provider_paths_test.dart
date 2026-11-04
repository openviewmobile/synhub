// Bug A 的**离线承重**用例：证明 `<dataDir>/app_flutter/downloads/<任意文件>`
// 真的能按 `file_paths.xml` 生成 `content://`（真机上造不出 uri 就是
// `Failed to find configured root that contains …` → 选择器永远弹不出来）。
//
// 这里跑的是**生产代码** `lib/src/core/file_provider_paths.dart`（FileProvider
// `SimplePathStrategy` 的纯 Dart 复刻），输入是**真实的**
// `android/app/src/main/res/xml/file_paths.xml` 与真机同形的目录布局 —— 所以
// 一旦有人把 `flutter_docs` 那条删掉，本文件的断言必挂（falsification 见最后一组）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/file_provider_paths.dart';

const String kPackage = 'com.openviewai.synhub';
const String kAuthority = '$kPackage.fileprovider';
const String kXmlPath = 'android/app/src/main/res/xml/file_paths.xml';
const String kManifestPath = 'android/app/src/main/AndroidManifest.xml';
const String kGradlePath = 'android/app/build.gradle.kts';
const String kKotlinBridgePath =
    'android/app/src/main/kotlin/com/openviewai/synhub/MediaOpenBridge.kt';

/// 修复前的 `file_paths.xml`（逐字复刻真机报错时磁盘上的内容）—— 用来做
/// "这套断言是承重的" 的反证。
const String kPreFixXml = '''
<?xml version="1.0" encoding="utf-8"?>
<paths>
    <cache-path name="chat_cache" path="chat_cache/"/>
    <cache-path name="cache_root" path="."/>
    <external-cache-path name="ext_cache" path="."/>
    <files-path name="files" path="."/>
    <external-files-path name="ext_files" path="."/>
</paths>
''';

String _read(String path) {
  final file = File(path);
  expect(
    file.existsSync(),
    isTrue,
    reason: '找不到 $path（flutter test 的 cwd 应为包根）',
  );
  return file.readAsStringSync();
}

void main() {
  // 真实文件的读取必须放在 `setUpAll` 里：`expect` 不能在测试体之外调用
  // （flutter_test 会抛 OutsideTestException）。
  late final List<FileProviderPathsRoot> roots;
  late final FileProviderDirs dirs;

  setUpAll(() {
    roots = parseFileProviderPathsXml(_read(kXmlPath));
    dirs = FileProviderDirs.forAndroidPackage(kPackage);
  });

  /// 真机上 App 实际交给 `viewLocal` 的路径（`getApplicationDocumentsDirectory()`
  /// = `Context.getDir("flutter")` = `<dataDir>/app_flutter`，下载落在 `downloads/`）。
  String appDocs(String name) =>
      '/data/user/0/$kPackage/app_flutter/downloads/$name';

  FileProviderResolution? resolve(String path) => resolveFileProviderUri(
    filePath: path,
    authority: kAuthority,
    roots: roots,
    dirs: dirs,
  );

  group('真实 file_paths.xml 覆盖 App 的 Flutter 文档目录', () {
    test('解析出 flutter_docs 根，且只指向 app_flutter（不整机、不 files 混用）', () {
      final docs = roots.where((r) => r.name == 'flutter_docs').toList();
      expect(docs, hasLength(1), reason: '缺少覆盖 app_flutter 的授权根');
      expect(docs.single.tag, 'files-path');
      expect(docs.single.path, '../app_flutter/');
      // 授权根 canonicalize 后必须**恰好**是 App 自己的文档目录
      final base = dirs.baseOf(docs.single.tag)!;
      expect(
        canonicalizePath('$base/${docs.single.path}'),
        '/data/user/0/$kPackage/app_flutter',
      );
      // 原始条目里不允许出现 root-path "."（整机可读文件都会落进根内）
      expect(
        roots.any((r) => r.tag == 'root-path' && r.path == '.'),
        isFalse,
        reason: 'root-path "." 安全面过大，不该出现',
      );
    });

    test('.mkv / .mp4 / .pdf：三类都能生成 content://（Bug A 的正断言）', () {
      for (final name in ['theora.mkv', 'clip-h264.mp4', 'probe-inline.pdf']) {
        final r = resolve(appDocs(name));
        expect(
          r,
          isNotNull,
          reason:
              '$name 不在任何授权根内 → 真机必报 '
              'Failed to find configured root',
        );
        expect(r!.root.name, 'flutter_docs');
        expect(r.uri, 'content://$kAuthority/flutter_docs/downloads/$name');
      }
    });

    test('同一缺陷的其它 viewLocal 路径（photos / vCard / drive / office 导出）也在根内', () {
      // 这些调用方都走 `<应用文档>/downloads`，所以一处 XML 修复覆盖全部；
      // 名字里带空格/中文也要能 encode 成合法 uri
      for (final name in [
        'IMG_0001.JPG',
        'contacts.vcf',
        'revision-2.docx',
        '年度报表.xlsx',
        'a b c.mp4',
      ]) {
        final r = resolve(appDocs(name));
        expect(r, isNotNull, reason: '$name 应被 flutter_docs 覆盖');
        expect(r!.uri, startsWith('content://$kAuthority/flutter_docs/'));
      }
      expect(
        resolve(appDocs('a b c.mp4'))!.uri,
        'content://$kAuthority/flutter_docs/downloads/a%20b%20c.mp4',
      );
    });
  });

  group('安全边界：不越权暴露其它目录', () {
    test('App 自己的非授权目录（databases / shared_prefs / 数据根）不命中', () {
      for (final path in [
        '/data/user/0/$kPackage/databases/app.db',
        '/data/user/0/$kPackage/shared_prefs/prefs.xml',
        '/data/user/0/$kPackage/app_flutter_old/downloads/x.mkv',
      ]) {
        expect(resolve(path), isNull, reason: '$path 不该被授权');
      }
    });

    test('其它包的数据目录不命中（哪怕字面上带 app_flutter）', () {
      expect(
        resolve('/data/user/0/com.other.app/app_flutter/downloads/x.mkv'),
        isNull,
      );
      expect(
        resolve('/data/data/$kPackage/../../com.other.app/files/x'),
        isNull,
      );
    });

    test('`..` 穿越被 canonicalize 消解后仍按授权根判定', () {
      // 从 app_flutter 里穿越出去 → 必须被拒
      expect(
        resolve('/data/user/0/$kPackage/app_flutter/../databases/app.db'),
        isNull,
      );
      // 从授权根外穿越进来 → 会被拒（真机 FileProvider 同样 canonicalize 后判定）
      expect(
        resolve(
          '/data/user/0/$kPackage/app_flutter/downloads/../../databases/x',
        ),
        isNull,
      );
      // 合法路径里带 `.` / 重复 `/` 仍应命中
      final r = resolve(
        '/data/user/0/$kPackage/app_flutter/./downloads//theora.mkv',
      );
      expect(r, isNotNull);
      expect(r!.uri, 'content://$kAuthority/flutter_docs/downloads/theora.mkv');
    });
  });

  group('既有路径回归：聊天附件分享/另存不受影响', () {
    test('chat_cache 命中更具体的 chat_cache 根（不是 cache_root "."）', () {
      final r = resolve('/data/user/0/$kPackage/cache/chat_cache/1/a.png');
      expect(r, isNotNull);
      expect(r!.root.name, 'chat_cache', reason: '多根命中取最长/最具体');
      expect(r.uri, 'content://$kAuthority/chat_cache/1/a.png');
    });

    test('缓存根下的其它文件仍走 cache_root', () {
      final r = resolve('/data/user/0/$kPackage/cache/other/x.tmp');
      expect(r, isNotNull);
      expect(r!.root.name, 'cache_root');
    });
  });

  group('falsification：这套断言确实是承重的', () {
    test('把 flutter_docs 那条去掉（修复前的 XML）→ 三类文件全都不命中', () {
      final legacy = parseFileProviderPathsXml(kPreFixXml);
      for (final name in ['theora.mkv', 'clip-h264.mp4', 'probe-inline.pdf']) {
        expect(
          resolveFileProviderUri(
            filePath: appDocs(name),
            authority: kAuthority,
            roots: legacy,
            dirs: dirs,
          ),
          isNull,
          reason: '修复前就该复现 Failed to find configured root',
        );
      }
    });

    test('从真实根列表里只删 flutter_docs → .mkv 立刻不命中（单点承重）', () {
      final without = roots.where((r) => r.name != 'flutter_docs').toList();
      expect(without.length, roots.length - 1);
      expect(
        resolveFileProviderUri(
          filePath: appDocs('theora.mkv'),
          authority: kAuthority,
          roots: without,
          dirs: dirs,
        ),
        isNull,
      );
    });

    test('只有 root-path "." 也能命中，但那会把整机目录一起纳入（弃用理由）', () {
      final rootPath = parseFileProviderPathsXml(
        '<paths><root-path name="root" path="."/></paths>',
      );
      expect(
        resolveFileProviderUri(
          filePath: appDocs('theora.mkv'),
          authority: kAuthority,
          roots: rootPath,
          dirs: dirs,
        ),
        isNotNull,
      );
      // 连别人家 App 的数据目录都能造 uri —— 这正是没有采用 root-path 的原因
      expect(
        resolveFileProviderUri(
          filePath: '/data/user/0/com.other.app/files/secret.db',
          authority: kAuthority,
          roots: rootPath,
          dirs: dirs,
        ),
        isNotNull,
      );
    });
  });

  group('provider 声明与代码里的 authority 一致', () {
    test('manifest 用 \${applicationId}.fileprovider，applicationId 无后缀', () {
      final manifest = _read(kManifestPath);
      expect(
        manifest.contains(
          'android:authorities="\${applicationId}.fileprovider"',
        ),
        isTrue,
      );
      expect(manifest.contains('android:exported="false"'), isTrue);
      expect(manifest.contains('android:grantUriPermissions="true"'), isTrue);
      expect(manifest.contains('android:resource="@xml/file_paths"'), isTrue);
      final gradle = _read(kGradlePath);
      expect(
        gradle.contains('applicationId = "$kPackage"'),
        isTrue,
        reason: 'applicationId 与测试假设的包名必须一致',
      );
      expect(
        gradle.contains('applicationIdSuffix'),
        isFalse,
        reason: '有后缀时 packageName != applicationId，authority 会对不上',
      );
    });

    test(
      'Kotlin 用 \${context.packageName}.fileprovider（运行时 == applicationId）',
      () {
        final kotlin = _read(kKotlinBridgePath);
        expect(
          kotlin.contains('"\${context.packageName}.fileprovider"'),
          isTrue,
        );
        // viewLocal / 分享两条都以该 authority 取 uri
        expect(
          RegExp('FileProvider.getUriForFile').allMatches(kotlin).length,
          2,
        );
      },
    );
  });
}
