// §1.4 守门：**请求 path 必须来自 `SYNO.API.Info`**，绝不能假设 `entry.cgi`。
//
// 为什么需要这条用例：真机实测（第 17 轮，`SYNO.API.Info?query=all`，1047 个 API）
// 发现 **28 个 API 根本不在 `entry.cgi`**：
//
//   SYNO.AudioStation.Album     → AudioStation/album.cgi
//   SYNO.AudioStation.Playlist  → AudioStation/playlist.cgi
//   SYNO.AudioStation.Song      → AudioStation/song.cgi
//   SYNO.DownloadStation.Task   → DownloadStation/task.cgi
//   SYNO.DownloadStation.Schedule → DownloadStation/schedule.cgi
//   …
//
// ⇒ 若哪个模块图省事写死 `entry.cgi`，这些功能会**整个不可用**，
// 而错误码是 `102`（"没有这个 API"）—— **看起来像服务端没装包，极难定位**。
//
// `DsmWebApi._prepare` 已经做对了（`entry.path` 优先、`_pathHint` 兜底），
// 本用例把这个行为钉住，防止以后有人"简化"成写死。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart';

/// 记录**每次请求实际用的 path**（`FakeTransport.calls` 只记 params，不含 path）。
class _PathRecordingTransport extends FakeTransport {
  _PathRecordingTransport(super.responses, super.apiTable);

  final List<String> paths = [];

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) {
    paths.add(path);
    return super.postForm(path, params);
  }
}

/// 一张**故意把 path 设成非 `entry.cgi`** 的能力表。
Map<String, Map<String, dynamic>> _table() => {
  ...FakeTransport.table,
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Auth': {'path': 'auth.cgi', 'minVersion': 1, 'maxVersion': 3},
  // 真机实测的形态：这两个 API 都不在 entry.cgi
  'SYNO.AudioStation.Album': {
    'path': 'AudioStation/album.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.DownloadStation.Task': {
    'path': 'DownloadStation/task.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  // 对照组：这个在 entry.cgi
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
  },
};

Future<DsmWebApi> _boot(_PathRecordingTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'u', password: 'p');
  return api;
}

void main() {
  group('§1.4 path 必须取自 SYNO.API.Info', () {
    test('能力表给了非 entry.cgi 的 path ⇒ 必须用那个 path', () async {
      final t = _PathRecordingTransport(const {}, _table());
      final api = await _boot(t);
      t.paths.clear();

      await api.call(
        'SYNO.AudioStation.Album',
        'list',
        preferredVersion: 3,
        params: {'offset': '0', 'limit': '10'},
      );

      expect(t.paths, hasLength(1));
      expect(
        t.paths.single,
        'AudioStation/album.cgi',
        reason: 'AudioStation 实测不在 entry.cgi；写死会让整个音乐模块 102',
      );
      expect(t.paths.single, isNot('entry.cgi'));
    });

    test('DownloadStation.Task 同理走 DownloadStation/task.cgi', () async {
      final t = _PathRecordingTransport(const {}, _table());
      final api = await _boot(t);
      t.paths.clear();

      await api.call(
        'SYNO.DownloadStation.Task',
        'list',
        preferredVersion: 3,
        params: {'offset': '0', 'limit': '10'},
      );

      expect(t.paths.single, 'DownloadStation/task.cgi');
    });

    test('对照组：能力表写 entry.cgi 的 API 就走 entry.cgi', () async {
      final t = _PathRecordingTransport(const {}, _table());
      final api = await _boot(t);
      t.paths.clear();

      await api.call(
        'SYNO.Foto.Browse.Item',
        'list',
        preferredVersion: 7,
        params: {'offset': '0', 'limit': '10'},
      );

      expect(t.paths.single, 'entry.cgi');
    });

    test('登录/discover 也各自走自己的 path（不是一律 entry.cgi）', () async {
      final t = _PathRecordingTransport(const {}, _table());
      await _boot(t);

      // 实测：discover 走 `encryption.cgi`（取 RSA 公钥）+ `auth.cgi`（登录）。
      expect(t.paths, contains('encryption.cgi'));
      expect(t.paths, contains('auth.cgi'));
      expect(
        t.paths,
        isNot(contains('entry.cgi')),
        reason: '登录链路不该碰 entry.cgi',
      );
    });

    test('能力表里没有该 API ⇒ apiNotFound（而不是瞎发到 entry.cgi）', () async {
      final t = _PathRecordingTransport(const {}, _table());
      final api = await _boot(t);
      t.paths.clear();

      await expectLater(
        api.call('SYNO.NoSuch.Module', 'list'),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.apiNotFound,
          ),
        ),
      );
      expect(t.paths, isEmpty, reason: '表里没有的 API 不该发出任何请求');
    });
  });
}
