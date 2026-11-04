// File Station C5（远程挂载 / 虚拟卷）+ 文件侧 P1 缺口的离线验证。
//
// 断言分三层：
//   1. **协议形状**：`api`/`method`/`version`/参数名必须与服务端权威注册表
//      （`/tmp/spk/export_FileStation/webapi/SYNO.FileStation.lib`）以及服务端
//      自带官方前端 `ui/file_browser/FileBrowser.js` 的调用点一致；
//   2. **凭据形态**：官方原文是**明文 `account` / `passwd`**（服务端
//      `IdentRecord::setPlainPasswd`），不能自作主张发 `cipherkey`；
//   3. **解析**：`Mount.List.get` 的 `mountConfig` / `isoList` / `remoteList`
//      与 WORM 状态的位掩码（`WormVo.State.isLocked()` = `value & 32`）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/dto/file_mount_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/cgi_encryption.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/file_mount.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _mountTable = {
  'SYNO.FileStation.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Mount': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.FileStation.Mount.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.FileStation.VirtualFolder': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Favorite': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Compress': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.FileStation.Extract': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

Future<({FileStationApi fs, FakeTransport t})> _makeApi({
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
}) async {
  final t = FakeTransport(Map<String, Map<String, dynamic>>.from(responses), {
    ...FakeTransport.table,
    ..._mountTable,
  });
  t.failures.addAll(failures);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (fs: FileStationApi(api), t: t);
}

void main() {
  group('C5 远程挂载：协议形状', () {
    test('Mount.List/get：v1，无参数，解析 isoList/remoteList/mountConfig', () async {
      final (:fs, :t) = await _makeApi(
        responses: {
          'SYNO.FileStation.Mount.List.get': {
            'mountConfig': {
              'enable_iso_mount': true,
              'enable_remote_mount': false,
            },
            'isoList': [
              {
                'type': 'iso',
                'source': '/volume1/iso/win.iso',
                'mount_point': '/volume1/win',
                'actor': 'l1',
                'date': 1758100000,
                'auto_mount': 'yes',
              },
            ],
            'remoteList': [
              {
                'type': 'cifs',
                'source': r'\\192.168.1.9\Share',
                'mount_point': '/volume1/smb',
                'actor': 'l1',
                'date': 1758100001,
                'auto_mount': 'fail',
              },
            ],
          },
        },
      );

      final list = await fs.listMounts();
      final call = t.calls.last;
      expect(call['api'], 'SYNO.FileStation.Mount.List');
      expect(call['method'], 'get');
      expect(call['version'], '1');

      expect(list.config.enableIsoMount, isTrue);
      expect(list.config.enableRemoteMount, isFalse);
      expect(list.isoList.single.mountPoint, '/volume1/win');
      expect(list.isoList.single.isIso, isTrue);
      expect(list.remoteList.single.mountType, FileMountType.cifs);
      expect(list.remoteList.single.autoMountFailed, isTrue);
      expect(list.all.length, 2);
    });

    test('Mount/mount_remote：CIFS + 明文 account/passwd（官方原文）', () async {
      final (:fs, :t) = await _makeApi();
      await fs.mountCifs(
        serverIp: r'\\192.168.1.9\Share',
        mountPoint: '/volume1/smb',
        userSet: true,
        account: 'u1',
        password: 'p1',
        autoMount: true,
      );
      final call = t.calls.last;
      expect(call['api'], 'SYNO.FileStation.Mount');
      expect(call['method'], 'mount_remote');
      expect(call['version'], '1');
      expect(call['mount_type'], 'CIFS');
      expect(call['server_ip'], r'\\192.168.1.9\Share');
      expect(call['mount_point'], '/volume1/smb');
      expect(call['user_set'], isTrue);
      expect(call['auto_mount'], isTrue);
      // 原文：FileAction.onMountRemote 把表单值直接放进 params
      expect(call['account'], 'u1');
      expect(call['passwd'], 'p1');
      // 不许"顺手加密"——那会变成服务端不认的字段
      expect(call.containsKey('cipherkey'), isFalse);
    });

    test('Mount/mount_remote：显式传 credentialCipher 时才发 cipherkey', () async {
      final kp = generateTestRsaKeyPair(2048);
      final pub = kp.publicKey as RSAPublicKey;
      final cipher = fakeCipherData(
        publicKeyB64: base64Encode(
          encodeX509RsaPublicKey(pub.modulus!, pub.exponent!),
        ),
      );
      final (:fs, :t) = await _makeApi();
      await fs.mountCifs(
        serverIp: r'\\h\s',
        mountPoint: '/volume1/s',
        userSet: false,
        account: 'u1',
        password: 'p1',
        credentialCipher: DsmCgiEncryption(cipher),
      );
      final call = t.calls.last;
      expect(call['__cIpHeRtExT'], isA<String>());
      expect(call.containsKey('account'), isFalse);
      expect(call.containsKey('passwd'), isFalse);
    });

    test('Mount/mount_iso：source/mount_point/auto_mount/user_set', () async {
      final (:fs, :t) = await _makeApi();
      await fs.mountIso(
        source: '/volume1/iso/win.iso',
        mountPoint: '/volume1/win',
        userSet: true,
        autoMount: false,
      );
      final call = t.calls.last;
      expect(call['method'], 'mount_iso');
      expect(call['source'], '/volume1/iso/win.iso');
      expect(call['mount_point'], '/volume1/win');
      expect(call['user_set'], isTrue);
      expect(call['auto_mount'], isFalse);
    });

    test('Mount/unmount：mount_type 用 iso/remote，不是 CIFS', () async {
      final (:fs, :t) = await _makeApi();
      await fs.unmountVolume(
        mountType: FileMountType.cifs.volumeValue,
        mountPoint: '/volume1/smb',
      );
      final call = t.calls.last;
      expect(call['method'], 'unmount');
      expect(call['mount_type'], 'remote');
      expect(call['is_mount_point'], isTrue);
      expect(call['mount_point'], '/volume1/smb');

      await fs.unmountVolume(
        mountType: FileMountType.iso.volumeValue,
        mountPoint: '/volume1/win',
        isMountPoint: false,
      );
      expect(t.calls.last['mount_type'], 'iso');
      expect(t.calls.last['is_mount_point'], isFalse);
    });

    test('Mount.List/unmount + reconnect：mount_point 是 JSON 数组串', () async {
      final (:fs, :t) = await _makeApi();
      await fs.unmountMounts(['/volume1/a', '/volume1/b']);
      expect(t.calls.last['api'], 'SYNO.FileStation.Mount.List');
      expect(t.calls.last['method'], 'unmount');
      expect(jsonDecode(t.calls.last['mount_point'] as String), [
        '/volume1/a',
        '/volume1/b',
      ]);

      await fs.reconnectMounts(['/volume1/a']);
      expect(t.calls.last['method'], 'reconnect');
      expect(jsonDecode(t.calls.last['mount_point'] as String), ['/volume1/a']);
    });

    test('Mount.List/remount：mount_type = iso/remote', () async {
      final (:fs, :t) = await _makeApi();
      await fs.remountAll(FileMountType.iso.volumeValue);
      expect(t.calls.last['method'], 'remount');
      expect(t.calls.last['mount_type'], 'iso');
    });

    test('VirtualFolder.list：iso 发裸字符串，cifs 发 JSON 数组', () async {
      final (:fs, :t) = await _makeApi();
      await fs.listVirtualFolders(type: const ['iso'], bareType: true);
      expect(t.calls.last['type'], 'iso');

      await fs.listVirtualFolders(type: const ['cifs']);
      expect(jsonDecode(t.calls.last['type'] as String), ['cifs']);
    });
  });

  group('C5 能力 / 权限门控', () {
    test('注册表缺 Mount / Mount.List → canManage=false', () async {
      final (:fs, :t) = await _makeApi();
      final cap = FileMountCapability.probe(fs);
      expect(t.apiTable.containsKey('SYNO.FileStation.Mount'), isTrue);
      expect(cap.canManage, isTrue);
      expect(cap.canMount, isTrue);
      expect(cap.canList, isTrue);

      // 只保留 List、去掉 Mount 系列：入口必须整个藏掉
      final t2 = FakeTransport({}, {
        ...FakeTransport.table,
        'SYNO.FileStation.List': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 2,
        },
      });
      final api2 = DsmWebApi(t2);
      await api2.discover();
      final none = FileMountCapability.probe(FileStationApi(api2));
      expect(none.canManage, isFalse);
      expect(none.canMount, isFalse);
      expect(none.canList, isFalse);
    });

    test('105 / 160 都算"没权限"', () {
      expect(isMountPermissionError(DsmErrorCode.noPermission), isTrue);
      expect(isMountPermissionError(DsmErrorCode.noAppPrivilege), isTrue);
      expect(isMountPermissionError(DsmErrorCode.badRequest), isFalse);
    });

    // ---- 官方「新增挂载」门控（FileBrowser.js offset 395,971 逐字）----
    //
    //   enable_remote_mount ? (is_admin || remote/home ? show : hide) : hide
    //   enable_iso_mount    ? show : hide
    group('官方新增挂载门控（enable_*_mount × is_admin/home）', () {
      const off = FileMountConfig();
      const onBoth = FileMountConfig(
        enableIsoMount: true,
        enableRemoteMount: true,
      );
      const onlyIso = FileMountConfig(enableIsoMount: true);
      const onlyRemote = FileMountConfig(enableRemoteMount: true);

      test('两类都没开 → 两个都不给（官方整格藏掉）', () {
        final g = FileMountGate.of(
          config: off,
          isAdmin: true,
          hasHome: true,
        );
        expect(g.remoteAllowed, isFalse);
        expect(g.isoAllowed, isFalse);
        expect(g.anyAllowed, isFalse);
      });

      test('服务器开了远程 + 管理员 → 给（不要求 home）', () {
        final g = FileMountGate.of(
          config: onlyRemote,
          isAdmin: true,
          hasHome: false,
        );
        expect(g.remoteAllowed, isTrue);
        expect(g.isoAllowed, isFalse);
      });

      test('服务器开了远程 + 非管理员 + 有 home → 给', () {
        final g = FileMountGate.of(
          config: onlyRemote,
          isAdmin: false,
          hasHome: true,
        );
        expect(g.remoteAllowed, isTrue);
      });

      test('★ 服务器开了远程 + 非管理员 + 没有 home → 不给（官方 hide）', () {
        final g = FileMountGate.of(
          config: onlyRemote,
          isAdmin: false,
          hasHome: false,
        );
        expect(g.remoteAllowed, isFalse);
        expect(g.anyAllowed, isFalse);
      });

      test('ISO 只看 enable_iso_mount（与身份/home 无关）', () {
        for (final admin in [true, false]) {
          for (final home in [true, false]) {
            final g = FileMountGate.of(
              config: onlyIso,
              isAdmin: admin,
              hasHome: home,
            );
            expect(g.isoAllowed, isTrue, reason: 'admin=$admin home=$home');
            expect(g.remoteAllowed, isFalse);
            expect(g.anyAllowed, isTrue);
          }
        }
      });

      test('两类都开：非管理员没 home 时只留 ISO（anyAllowed 仍为真）', () {
        final g = FileMountGate.of(
          config: onBoth,
          isAdmin: false,
          hasHome: false,
        );
        expect(g.remoteAllowed, isFalse);
        expect(g.isoAllowed, isTrue);
        expect(g.anyAllowed, isTrue);
      });

      test('两类都开：非管理员有 home 时两个都给', () {
        final g = FileMountGate.of(
          config: onBoth,
          isAdmin: false,
          hasHome: true,
        );
        expect(g.remoteAllowed, isTrue);
        expect(g.isoAllowed, isTrue);
      });
    });

    test(
      'Mount.List/get 回 105 → API 原样抛出（provider 翻成 permissionDenied）',
      () async {
        final t = FakeTransport({}, {...FakeTransport.table, ..._mountTable});
        t.failures['SYNO.FileStation.Mount.List.get'] =
            DsmErrorCode.noPermission;
        final api = DsmWebApi(t);
        await api.discover();
        await api.login(account: 'a', password: 'b');
        // 直接走 API：错误原样抛出，由 provider 翻译成"没权限"
        await expectLater(
          FileStationApi(api).listMounts(),
          throwsA(
            isA<DsmApiException>().having(
              (e) => e.code,
              'code',
              DsmErrorCode.noPermission,
            ),
          ),
        );
      },
    );
  });

  group('WORM（P1-6）状态解析', () {
    test('位掩码：locked = value & 32（官方 WormVo.State）', () {
      // 线上下标 4/5/8/9 → 位掩码 32/33/34/35 → 锁定
      for (final s in [4, 5, 8, 9]) {
        expect(
          FileWormState.isLocked(FileWormState.normalize(s)),
          isTrue,
          reason: 'state $s',
        );
      }
      for (final s in [0, 1, 2, 3, 6, 7]) {
        expect(
          FileWormState.isLocked(FileWormState.normalize(s)),
          isFalse,
          reason: 'state $s',
        );
      }
      expect(FileWormState.isOpen(FileWormState.normalize(3)), isTrue);
      expect(FileWormState.isExpired(FileWormState.normalize(6)), isTrue);
      // 位掩码常量也认（有的接口直接给 32/33/34/35/64/65）
      expect(FileWormState.normalize(32), FileWormState.immutableLocked);
      expect(FileWormState.normalize(35), FileWormState.weakAppendableLocked);
      expect(FileWormState.normalize(7), FileWormState.appendableExpired);
      // 下标 → 位掩码的完整映射
      expect(
        [for (var i = 0; i <= 9; i++) FileWormState.normalize(i)],
        [0, 16, 17, 18, 32, 33, 64, 65, 34, 35],
      );
    });

    test('FileEntryDto.wormLocked / isReadOnly', () {
      final locked = FileEntryDto.fromJson({
        'name': 'a.txt',
        'path': '/home/a.txt',
        'additional': {
          'worm_state': 4,
          'perm': {
            'acl': {'read': true, 'write': true},
          },
        },
      });
      expect(locked.wormLocked, isTrue);
      expect(locked.permKnown, isTrue);
      expect(locked.isReadOnly, isFalse);

      // 只读：有 perm 但 write=false
      final ro = FileEntryDto.fromJson({
        'name': 'b.txt',
        'path': '/home/b.txt',
        'additional': {
          'perm': {
            'acl': {'read': true, 'write': false},
          },
        },
      });
      expect(ro.isReadOnly, isTrue);
      expect(ro.wormLocked, isFalse);

      // 没带 perm：不能当成只读
      final unknown = FileEntryDto.fromJson({'name': 'c', 'path': '/home/c'});
      expect(unknown.permKnown, isFalse);
      expect(unknown.isReadOnly, isFalse);
      expect(unknown.wormLocked, isFalse);

      // 过期态恢复删除/改名
      final expired = FileEntryDto.fromJson({
        'name': 'd',
        'path': '/home/d',
        'additional': {'worm_state': 6},
      });
      expect(expired.wormLocked, isFalse);
    });
  });

  group('P1-7 收藏 edit / clear_broken', () {
    test('Favorite/edit：name + path + index，version 2', () async {
      final (:fs, :t) = await _makeApi();
      await fs.editFavorite('/home/a', name: '新名字');
      final call = t.calls.last;
      expect(call['api'], 'SYNO.FileStation.Favorite');
      expect(call['method'], 'edit');
      expect(call['version'], '2');
      expect(call['name'], '新名字');
      expect(call['path'], '/home/a');
      // 官方对话框固定发 index:-1（同一父节点内的排序位，-1 = 不变）
      expect('${call['index']}', '-1');
    });

    test('Favorite/clear_broken：version 2，不带任何业务参数', () async {
      final (:fs, :t) = await _makeApi();
      await fs.clearBrokenFavorites();
      final call = t.calls.last;
      expect(call['api'], 'SYNO.FileStation.Favorite');
      expect(call['method'], 'clear_broken');
      expect(call['version'], '2');
      final business = call.keys.where(
        (k) => !{'api', 'method', 'version', '_sid'}.contains(k),
      );
      expect(business, isEmpty, reason: 'clear_broken 原文没有参数');
    });
  });

  group('P1-4 / P1-5 参数形状', () {
    test('compress 带 format/level；extract 带 codepage', () async {
      final (:fs, :t) = await _makeApi();
      await fs.startCompress(
        paths: const ['/home/a.txt'],
        destFilePath: '/home/a.7z',
        format: '7z',
        level: 'store',
      );
      expect(t.calls.last['api'], 'SYNO.FileStation.Compress');
      expect(t.calls.last['format'], '7z');
      expect(t.calls.last['level'], 'store');
      // 默认档线上值 = 官方 APK 的 `replace`（服务端 `.so` 未给默认档命名）。
      expect(t.calls.last['mode'], 'replace');

      await fs.startExtract(
        filePath: '/home/a.zip',
        destFolderPath: '/home',
        codepage: 'chs',
      );
      expect(t.calls.last['api'], 'SYNO.FileStation.Extract');
      expect(t.calls.last['codepage'], 'chs');

      // 不指定编码时**不发** codepage（服务端默认）
      await fs.startExtract(filePath: '/home/a.zip', destFolderPath: '/home');
      expect(t.calls.last.containsKey('codepage'), isFalse);
    });

    // ★ 第 250 轮补：审计行 142（M22 压缩加密）与 145（M25 解压密码包）的
    // **客户端侧契约断言**。权威依据：`docs/api-server-authoritative.md:1131-1132`
    // （`Compress.start`/`Extract.start` 的参数表里 `password` 是可选字段，
    //  来自 FileStation SPK 的 `.so` 字符串 `strings --preset params`）。
    //
    // ⚠️ 诚实边界：这里只证"**我们发得对**"（非空才发、字段名/位置与服务端参数表一致）。
    //   "服务端拿到 password 后真的用 AES 加密、7-Zip 能回开"属**服务端语义**，
    //   需要真机造加密包（变更动词）⇒ **未验**，台账按此标注。
    test('compress 密码：非空才发 password，空串不发', () async {
      final (:fs, :t) = await _makeApi();
      await fs.startCompress(
        paths: const ['/home/a.txt'],
        destFilePath: '/home/a.zip',
        password: 's3cret',
      );
      expect(t.calls.last['api'], 'SYNO.FileStation.Compress');
      expect(t.calls.last['password'], 's3cret');

      await fs.startCompress(
        paths: const ['/home/a.txt'],
        destFilePath: '/home/a.zip',
        password: '',
      );
      expect(
        t.calls.last.containsKey('password'),
        isFalse,
        reason: '空串等于没设密码 ⇒ 不发（服务端默认无密码）',
      );
    });

    test('extract / list 密码：非空才发 password', () async {
      final (:fs, :t) = await _makeApi();
      await fs.startExtract(
        filePath: '/home/a.zip',
        destFolderPath: '/home',
        password: 's3cret',
        codepage: 'utf8',
      );
      expect(t.calls.last['password'], 's3cret');
      expect(t.calls.last['codepage'], 'utf8');

      await fs.startExtract(
        filePath: '/home/a.zip',
        destFolderPath: '/home',
      );
      expect(t.calls.last.containsKey('password'), isFalse);

      await fs.listArchive(filePath: '/home/a.zip', password: 's3cret');
      expect(t.calls.last['api'], 'SYNO.FileStation.Extract');
      expect(t.calls.last['method'], 'list');
      expect(t.calls.last['password'], 's3cret');
    });
  });
}
