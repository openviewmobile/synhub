// Android `FileProvider` 的"这个本地路径能不能生成 `content://`"判定 —— **纯 Dart
// 复刻**，与 `android/app/src/main/res/xml/file_paths.xml` 一一对应。
//
// 为什么需要它（真机 bug 的离线承重）：
//   真机上 `MediaOpenBridge.viewLocal` 调 `FileProvider.getUriForFile`，路径
//   `<dataDir>/app_flutter/downloads/…` 不在 `file_paths.xml` 的任何授权根里时抛
//   `IllegalArgumentException: Failed to find configured root that contains …`，
//   原生只 log 一行 `FileProvider 拿不到 uri` 就返回 false → 选择器根本没机会弹。
//   这类缺陷在 `flutter test` 里原本**完全无法复现**（没有 Android 运行时），所以
//   把 FileProvider 的授权根解析 / canonicalize / contain 判定抽成这里的纯函数，
//   测试直接读**真实的** `file_paths.xml` + 真机同形的 `<dataDir>` 布局来断言。
//
// 复刻依据（androidx.core `FileProvider$SimplePathStrategy`，已核对 1.13.1 与
// 1.18.0 两版字节码）：
//   * `<files-path>` → `context.getFilesDir()`、`<cache-path>` → `getCacheDir()`、
//     `<external-files-path>` → 首个外部 files dir、`<external-cache-path>` → 首个外部
//     cache dir、`<root-path>` → `/`；
//   * root = `new File(base, path).getCanonicalFile()`（因此 `..` 会被消解）；
//   * 命中判定 = 文件 `getCanonicalPath()` 与 root `getPath()` 做
//     `path == root || path.startsWith('$root/')`（**带 `/`**，1.18 的 `belongsToRoot`），
//     多个根命中时取**最长**的那个；
//   * uri = `content://<authority>/<rootName>/<相对路径>`（两段都做 Android 式
//     percent-encode）。
//
// 这里**不 import flutter**：可以 `dart run` 直接跑，也能在 `flutter test` 里断言。

/// `file_paths.xml` 里的一个授权根条目。
class FileProviderPathsRoot {
  const FileProviderPathsRoot({
    required this.tag,
    required this.name,
    this.path = '',
  });

  /// `files-path` / `cache-path` / `external-path` / `external-files-path` /
  /// `external-cache-path` / `external-media-path` / `root-path`
  final String tag;

  /// `android:name`（uri 的第一段）
  final String name;

  /// `android:path`（相对基目录；缺省 = `''`，语义同 `"."`）
  final String path;

  @override
  String toString() => '<$tag name="$name" path="$path"/>';
}

/// 解析 `file_paths.xml` 的 `<paths>` 子元素。
///
/// 只有这一种极简形状（自闭合/单层、属性都是双引号），不值得为它引 XML 依赖；
/// 解析不了的行**直接忽略**，解析结果为空时调用方应视为"配置缺失"。
List<FileProviderPathsRoot> parseFileProviderPathsXml(String xml) {
  const tags = {
    'files-path',
    'cache-path',
    'external-path',
    'external-files-path',
    'external-cache-path',
    'external-media-path',
    'root-path',
  };
  final result = <FileProviderPathsRoot>[];
  // 先去注释：`file_paths.xml` 的注释里**会举例子**（本文件就写了
  // `<root-path name="root" path="." />` 作为"为什么不这么配"），
  // 不剥掉的话那些示例会被当成真的授权根。
  final body = xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  final element = RegExp(r'<([a-z-]+)\b([^>]*?)/?>');
  for (final m in element.allMatches(body)) {
    final tag = m.group(1)!;
    if (!tags.contains(tag)) continue;
    final attrs = m.group(2) ?? '';
    final name = _attr(attrs, 'name');
    if (name == null || name.isEmpty) continue;
    result.add(
      FileProviderPathsRoot(
        tag: tag,
        name: name,
        path: _attr(attrs, 'path') ?? '',
      ),
    );
  }
  return result;
}

String? _attr(String attrs, String key) =>
    RegExp('$key\\s*=\\s*"([^"]*)"').firstMatch(attrs)?.group(1);

/// FileProvider 各 tag 的基目录（真机上的实际值由 `Context` 给出，测试用同形布局）。
class FileProviderDirs {
  const FileProviderDirs({
    required this.filesDir,
    required this.cacheDir,
    this.externalDir = '/storage/emulated/0',
    String? externalFilesDir,
    String? externalCacheDir,
    this.externalMediaDir = '/storage/emulated/0/Android/media',
  }) : _externalFilesDir = externalFilesDir,
       _externalCacheDir = externalCacheDir;

  final String filesDir;
  final String cacheDir;
  final String externalDir;
  final String? _externalFilesDir;
  final String? _externalCacheDir;
  final String externalMediaDir;

  String? get externalFilesDir => _externalFilesDir;

  String? get externalCacheDir => _externalCacheDir;

  /// 按 Android 的真机布局给某个包名造一套目录（`<dataDir>` = `/data/user/0/<pkg>`）。
  ///
  /// 注意 `path_provider` 的 `getApplicationDocumentsDirectory()` 在这套布局里是
  /// `<dataDir>/app_flutter`（`Context.getDir("flutter")`），**不在** [filesDir] 下。
  factory FileProviderDirs.forAndroidPackage(String packageName) {
    final data = '/data/user/0/$packageName';
    return FileProviderDirs(
      filesDir: '$data/files',
      cacheDir: '$data/cache',
      externalFilesDir: '/storage/emulated/0/Android/data/$packageName/files',
      externalCacheDir: '/storage/emulated/0/Android/data/$packageName/cache',
    );
  }

  /// tag → 基目录；未知 tag / 该 ROM 没有对应外部目录 → null（该根不成立）。
  String? baseOf(String tag) => switch (tag) {
    'files-path' => filesDir,
    'cache-path' => cacheDir,
    'external-path' => externalDir,
    'external-files-path' => _externalFilesDir,
    'external-cache-path' => _externalCacheDir,
    'external-media-path' => externalMediaDir,
    'root-path' => '/',
    _ => null,
  };
}

/// 命中结果：哪个根 + 生成的 `content://` uri（uri == null 时该根不可用）。
class FileProviderResolution {
  const FileProviderResolution({required this.root, required this.uri});

  final FileProviderPathsRoot root;

  /// `content://<authority>/<name>/<相对路径>`
  final String uri;

  @override
  String toString() => '$uri (root=${root.name})';
}

/// 复刻 `FileProvider.getUriForFile`。
///
/// 返回 null = 没有任何授权根包含该路径（真机上即抛
/// `Failed to find configured root that contains …`，`content://` 造不出来）。
FileProviderResolution? resolveFileProviderUri({
  required String filePath,
  required String authority,
  required List<FileProviderPathsRoot> roots,
  required FileProviderDirs dirs,
}) {
  final canonical = canonicalizePath(filePath);
  FileProviderPathsRoot? best;
  String? bestRootPath;
  for (final root in roots) {
    final base = dirs.baseOf(root.tag);
    if (base == null) continue;
    final rootPath = canonicalizePath(
      root.path.isEmpty ? base : '$base/${root.path}',
    );
    if (!_belongsToRoot(canonical, rootPath)) continue;
    // 多个根都命中时取最长（更具体）的那个，与 SimplePathStrategy 一致
    if (bestRootPath == null || rootPath.length > bestRootPath.length) {
      best = root;
      bestRootPath = rootPath;
    }
  }
  if (best == null || bestRootPath == null) return null;
  final relative = canonical == bestRootPath
      ? ''
      : canonical.substring(bestRootPath.length + 1);
  return FileProviderResolution(
    root: best,
    uri:
        'content://$authority/${_encode(best.name)}'
        '/${_encode(relative, allow: '/')}',
  );
}

/// `path == root || path.startsWith('$root/')`（带分隔符，避免
/// `<data>/app_flutter_old` 被 `<data>/app_flutter` 误命中）。
bool _belongsToRoot(String path, String root) =>
    path == root || path.startsWith(root.endsWith('/') ? root : '$root/');

/// 词法 canonicalize：消解 `.` / `..` / 重复 `/`。与 Java `File.getCanonicalPath`
/// 对"已存在的路径前缀 + 不存在的尾段"的结果一致（不解析 symlink，本用途不需要）。
String canonicalizePath(String path) {
  final absolute = path.startsWith('/');
  final parts = <String>[];
  for (final segment in path.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (parts.isNotEmpty && parts.last != '..') {
        parts.removeLast();
      } else if (!absolute) {
        parts.add('..');
      }
      continue;
    }
    parts.add(segment);
  }
  final joined = parts.join('/');
  return absolute ? '/$joined' : joined;
}

/// Android `Uri.encode(s, allow)` 的等价实现（保留 `A-Za-z0-9_-!.~'()*`）。
String _encode(String value, {String allow = ''}) {
  const unreserved =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  const extra = "-_.!~'()*";
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    final ch = String.fromCharCode(rune);
    if (unreserved.contains(ch) || extra.contains(ch) || allow.contains(ch)) {
      buffer.write(ch);
    } else {
      for (final byte in _utf8BytesOf(rune)) {
        buffer.write(
          '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}',
        );
      }
    }
  }
  return buffer.toString();
}

/// 一个 code point 的 UTF-8 字节（Android `Uri.encode` 对非 ASCII 按 UTF-8 打点）。
List<int> _utf8BytesOf(int rune) {
  if (rune <= 0x7F) return [rune];
  if (rune <= 0x7FF) {
    return [0xC0 | (rune >> 6), 0x80 | (rune & 0x3F)];
  }
  if (rune <= 0xFFFF) {
    return [
      0xE0 | (rune >> 12),
      0x80 | ((rune >> 6) & 0x3F),
      0x80 | (rune & 0x3F),
    ];
  }
  return [
    0xF0 | (rune >> 18),
    0x80 | ((rune >> 12) & 0x3F),
    0x80 | ((rune >> 6) & 0x3F),
    0x80 | (rune & 0x3F),
  ];
}
