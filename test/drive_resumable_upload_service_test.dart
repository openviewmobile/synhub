// ★★ **③Drive 第 51 轮：D24 续传**服务的三条"安静出错"路径**必须被钉住**
//
// ## 被测物
// `lib/src/features/drive/drive_resumable_upload.dart`
// —— 逐字对齐官方 `FileUploadRecoverableWork.java:99-135` 的两步流程。
//
// ## 为什么必须有这份用例
// 这段编排有三条路径，**写错了功能照样"能用"、没有任何报错**：
//
// ① **能力位为假**时不能去调续传接口 —— 否则在不支持的老服务端上是
//    一次注定失败的请求，而用户看到的是"上传失败"（真正的上游原因被吞掉）。
// ② **探测失败**时必须回落普通上传 —— 官方 `mOffset = -1L` 就是这个语义。
//    若把探测异常直接抛给用户，**一张照片上传失败**只因服务端不支持探测。
// ③ 探测回 **`offset >= 全长`**（服务端其实已收完）时**不能再传一遍** ——
//    重传会让服务端再建一份（或触发冲突改名），用户看到"重复文件"。
//
// ## 另一个必须钉的：官方**不切块**
// 官方是"探测 → 一次传完余量"，**没有客户端分片循环**。
// 我一度以为要写循环；查了 `onPrepareRequestWork` 只有 index 0/1 两步才确认。
// 用例把"只发一次 chunk 请求"钉住，防止以后有人凭印象加循环。
//
// 全程内存 Mock，不碰真机（规程 §5.1）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/drive/drive_resumable_upload.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

late Directory _tmp;

/// 造一个指定大小的真实文件（`lengthSync` 必须是真的）。
String _file(String name, int bytes) {
  final f = File('${_tmp.path}/$name');
  f.writeAsBytesSync(List<int>.filled(bytes, 7));
  return f.path;
}

void main() {
  late MockDsmBackend backend;
  late MockDsmTransport transport;
  late DsmWebApi web;
  late DriveApi drive;

  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('drive_resume_');
  });
  tearDownAll(() async {
    if (_tmp.existsSync()) await _tmp.delete(recursive: true);
  });

  setUp(() async {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    backend.login(username: 'demo_user', admin: false);
    transport = MockDsmTransport(backend);
    web = DsmWebApi(transport);
    await web.discover();
    await web.login(account: 'demo_user', password: 'x');
    drive = DriveApi(web);
  });

  /// 让探针回一个确定的已收字节数。
  void probe(String api, int uploadedSize) => backend.fixture(
    api,
    'upload',
    (_) => {
      'success': true,
      'data': {'uploaded_size': uploadedSize},
    },
  );

  group('DR-1. ★★ 能力位为假 ⇒ **不许**走续传', () {
    test('★★ 服务端不支持时 `shouldResumeUpload` = false', () {
      expect(
        shouldResumeUpload(
          fileSizeBytes: 999 * 1024 * 1024,
          serverSupportsRecoverable: false,
        ),
        isFalse,
        reason: '★ `Files.maxVersion < 9` 时官方 getOffset() 就返回 -1L',
      );
    });

    test('★★ 太小 ⇒ 回落整文件分支（不再是"抛异常"占位行为）', () async {
      // 造一个不支持续传的 DriveApi：直接用一个没有 Files 的目录。
      final b2 = MockDsmBackend(catalog: DsmCatalog.load());
      b2.login(username: 'demo_user', admin: false); // ★ 不登录上传会回 119
      final t = MockDsmTransport(b2);
      final api2 = DsmWebApi(t);
      await api2.discover();
      // ★ backend 登录 ≠ webapi 登录：`postMultipart` 的 `_sid` 取自
      // `api.session`，只登 backend 的话 `_sid` 是空串 ⇒ 119。
      await api2.login(account: 'demo_user', password: 'x');
      final d2 = DriveApi(api2);
      // Mock 目录里 Files=11 ⇒ 支持；这里显式验证"支持"那一侧，
      // "不支持"一侧由 shouldResumeUpload 的纯函数用例覆盖（不需要真请求）。
      expect(d2.isSupportRecoverableTransfer, isTrue);

      // ⚠️ 第 52 轮行为变更：整文件分支（`Files/upload`）已实现，
      // 所以"不续传"现在**正确回落**到它，而不是抛异常 ——
      // 这正是官方 `FileUploadRecoverableWork` 的 `DummyWork`→`FileUploadWork` 语义。
      // （旧断言钉的是**占位行为**"还没实现所以抛异常"，属修正而非迁就。）
      // ⚠️ `d2` 用的是**另一个** transport（`t`），断言必须看 `t.lastUpload`；
      // 我第一次写成 `transport`（setUp 里那个），拿到 null 而找不到原因。
      t.lastUpload = null;
      final out = await driveResumableUpload(
        d2,
        folderId: '1',
        filePath: _file('tiny.bin', 10),
        fileName: 'tiny.bin',
        taskId: 't1',
        tempDir: _tmp.path,
        // 阈值调高到对 10 字节文件也"算小"
        thresholdBytes: 1024,
      );
      expect(out.resumed, isFalse, reason: '★ 太小 ⇒ 不走续传');
      expect(out.offset, -1, reason: '★ offset=-1 就是官方"整文件"的标记');
      final f0 = t.lastUpload!.fields;
      expect(f0['api'], 'SYNO.SynologyDrive.Files');
      expect(f0['method'], 'upload');
      expect(
        f0['version'],
        '8',
        reason: '★ 整文件分支是 Math.min(8, maxVersion)，与分片的 2 不同',
      );
    });

    test('★ 阈值边界：`>=` 阈值才算大文件', () {
      expect(
        shouldResumeUpload(
          fileSizeBytes: 100,
          serverSupportsRecoverable: true,
          thresholdBytes: 100,
        ),
        isTrue,
      );
      expect(
        shouldResumeUpload(
          fileSizeBytes: 99,
          serverSupportsRecoverable: true,
          thresholdBytes: 100,
        ),
        isFalse,
      );
    });
  });

  group('DR-2. ★★★ 探测回来一个偏移 ⇒ 必须**带着它**续传（这才是断点续传）', () {
    test('★★★ 服务端说已收 4096 ⇒ uploadChunk 的 offset 必须是 4096', () async {
      probe('SYNO.SynologyDrive.Files', 4096);
      final p = _file('big1.bin', 10000);

      final out = await driveResumableUpload(
        drive,
        folderId: 'id:973840842603147299',
        filePath: p,
        fileName: 'big1.bin',
        taskId: 'tk-1',
        tempDir: _tmp.path,
        thresholdBytes: 1024,
      );

      expect(out.resumed, isTrue);
      expect(out.offset, 4096, reason: '★★★ 这就是断点续传的全部意义：不是从 0 重传');
      final h = transport.lastUpload!.headers;
      expect(h['X-FILE-CHUNK-END'], 'true', reason: '续传那一次是 true');
      expect(h['X-TMP-FILE'], 'tk-1');
      expect(
        transport.lastUpload!.fields['path'],
        'id:973840842603147299/big1.bin',
      );
    });

    test('★ 服务端说 0 ⇒ offset 0（从头传，但走的仍是续传通道）', () async {
      probe('SYNO.SynologyDrive.Files', 0);
      final p = _file('big2.bin', 10000);
      final out = await driveResumableUpload(
        drive,
        folderId: '1',
        filePath: p,
        fileName: 'big2.bin',
        taskId: 'tk-2',
        tempDir: _tmp.path,
        thresholdBytes: 1024,
      );
      expect(out.offset, 0);
      expect(out.resumed, isTrue);
    });
  });

  group('DR-3. ★★★ 探测失败 ⇒ 回落普通上传（官方的 `mOffset = -1`）', () {
    test('★★★ 探测抛错时**不**把异常抛给用户，而是退回 FallbackRequired', () async {
      // ⚠️ 夹具只让**探针**失败，不能让落回的整文件上传也失败 ——
      // 否则测的就不是"回落"而是"两条路都断了"。
      // 区分依据：探针的 fields 只有 api/method/version（**没有 `path`**），
      // 整文件/续传都有 `path`。
      backend.fixture(
        'SYNO.SynologyDrive.Files',
        'upload',
        (params) => params.containsKey('path')
            ? {
                'success': true,
                'data': {'file_id': 'fid-1'},
              }
            : {
                'success': false,
                'error': {'code': 103},
              },
      );
      final p = _file('big3.bin', 10000);
      transport.lastUpload = null;
      final out = await driveResumableUpload(
        drive,
        folderId: '1',
        filePath: p,
        fileName: 'big3.bin',
        taskId: 'tk-3',
        tempDir: _tmp.path,
        thresholdBytes: 1024,
      );
      expect(out.resumed, isFalse);
      expect(
        out.offset,
        -1,
        reason:
            '★ 官方 mOffset = -1L ⇒ 没得续就普通传；'
            '把探测异常抛给用户会让"服务端不支持探测"变成"照片传不上去"',
      );
      final h = transport.lastUpload!.headers;
      expect(
        h['X-FILE-CHUNK-END'],
        isNot('true'),
        reason: '★ 回落这次**不能**带续传头（否则服务端按分片处理）',
      );
      // 落回的必须是**整文件分支**（版本 8），不是分片分支（版本 2）
      expect(transport.lastUpload!.fields['version'], '8');
    });

    test('★ dummy 文件必须被清理（不留垃圾在临时目录）', () async {
      probe('SYNO.SynologyDrive.Files', 512);
      final p = _file('big4.bin', 10000);
      await driveResumableUpload(
        drive,
        folderId: '1',
        filePath: p,
        fileName: 'big4.bin',
        taskId: 'tk-clean',
        tempDir: _tmp.path,
        thresholdBytes: 1024,
      );
      final leftovers = _tmp
          .listSync()
          .where((e) => e.path.contains('dummy'))
          .toList();
      expect(leftovers, isEmpty, reason: '★ dummy 只在探测时用，必须删掉');
    });
  });

  group('DR-4. ★★★ 探测回 `offset >= 全长` ⇒ 服务端已收完，**不许重传**', () {
    test('★★★ 已收 == 全长 ⇒ resumed=true 但**不发 chunk**（不再重复上传）', () async {
      probe('SYNO.SynologyDrive.Files', 10000);
      final p = _file('done.bin', 10000);

      transport.lastUpload = null;
      final out = await driveResumableUpload(
        drive,
        folderId: '1',
        filePath: p,
        fileName: 'done.bin',
        taskId: 'tk-done',
        tempDir: _tmp.path,
        thresholdBytes: 1024,
      );

      expect(out.offset, 10000);
      expect(out.resumed, isTrue, reason: '走的确实是续传这条判断路径');
      expect(
        transport.lastUpload!.headers['X-FILE-CHUNK-END'],
        'false',
        reason:
            '★★★ 最后一次 multipart 必须还是**探针**（false）——'
            '若变成 true 就说明又传了一遍，服务端会出现重复文件/冲突改名',
      );
    });

    test('★ 已收 **超过** 全长（异常但可能）也当作完成', () async {
      probe('SYNO.SynologyDrive.Files', 999999);
      final p = _file('over.bin', 100);
      transport.lastUpload = null;
      final out = await driveResumableUpload(
        drive,
        folderId: '1',
        filePath: p,
        fileName: 'over.bin',
        taskId: 'tk-over',
        tempDir: _tmp.path,
        thresholdBytes: 10,
      );
      expect(out.resumed, isTrue);
      expect(transport.lastUpload!.headers['X-FILE-CHUNK-END'], 'false');
    });
  });

  group('DR-4b. ★★ UI 链路的两个关键前提（目录 id 解析 / 落点前缀）', () {
    test('★★ `Files/get` 的 `file_id` 决定上传落点 `id:<fileId>/<name>`', () async {
      // UI 侧用 `(await drive.get(path: path)).pathId` 拿当前目录 id
      // （`DriveEntryDto.pathId = 'id:$fileId'`）。
      backend.fixture(
        'SYNO.SynologyDrive.Files',
        'get',
        (_) => {
          'success': true,
          'data': {'file_id': '973840842603147299'},
        },
      );
      final folderId = (await drive.get(path: '/mydrive/Photos')).pathId;
      expect(folderId, 'id:973840842603147299');

      probe('SYNO.SynologyDrive.Files', 0);
      final p = _file('wired.bin', 10000);
      await driveResumableUpload(
        drive,
        folderId: folderId,
        filePath: p,
        fileName: 'wired.bin',
        taskId: 'tk-wired',
        tempDir: _tmp.path,
        thresholdBytes: 1024,
      );
      expect(
        transport.lastUpload!.fields['path'],
        'id:973840842603147299/wired.bin',
        reason:
            '★★ 这是"能传进团队文件夹"的根据：落点只看 file_id，'
            '与目录在哪个产品域无关',
      );
    });

    test('★ 目录 id 解析失败时调用方应能察觉（UI 据此退回 FileStation）', () async {
      // 回包里没有 file_id ⇒ pathId 是 "id:"（空 id）
      backend.fixture(
        'SYNO.SynologyDrive.Files',
        'get',
        (_) => {'success': true, 'data': <String, dynamic>{}},
      );
      final entry = await drive.get(path: '/mydrive/X');
      // ★ 这个用例本来是记录"CURRENT 现状"的，结果暴露了一个真弱点：
      // 若只判 `folderId != null`，空 id 会走到 Drive 上传得到 `id:/<name>`
      // 这种无意义落点并失败。已据此加固 UI（`resolved.length > 3` 才用）。
      expect(entry.pathId, 'id:', reason: '回包缺 file_id ⇒ pathId 是 "id:"（长度 3）');
      expect(
        entry.pathId.length > 3,
        isFalse,
        reason: '★ UI 的判据必须比 `!= null` 更严 —— 这就是加固的那一条',
      );
    });
  });

  group('DR-5. ★ 官方**不切块**：只是一次探测 + 一次上传', () {
    test('★★ 整个续传编排只发出 **2** 次 multipart（1 探针 + 1 上传）', () async {
      probe('SYNO.SynologyDrive.Files', 2048);
      final p = _file('noloop.bin', 10000);

      final before = backend.requests.length;
      await driveResumableUpload(
        drive,
        folderId: '1',
        filePath: p,
        fileName: 'noloop.bin',
        taskId: 'tk-2step',
        tempDir: _tmp.path,
        thresholdBytes: 1024,
      );
      final after = backend.requests.length;

      expect(
        after - before,
        2,
        reason:
            '★★ 官方 onPrepareRequestWork 只有 index 0（探测）与 1（上传）两步；'
            '客户端不切块 —— 写成循环会把同一个文件重复传 N 次',
      );
    });
  });
}
