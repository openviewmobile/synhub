// ★★ **③Drive 第 50 轮：D24 分片续传上传 —— 协议级 Mock 验证**
//
// ## 官方依据（`docs/drive-upload-protocol-authoritative.md` 是本文件的取证底稿）
// 来源：官方 **Synology Drive Android 3.9.0-1113** 反编译
// `/tmp/drive-apk/jadx/.../api/ApiSynoDriveFiles.java`
//
// * 驱动 API 是 `SYNO.SynologyDrive.Files/upload`（`:43,84`）—— **不是** FileStation；
// * 分片分支（`offset > -1`）版本 **`min(2, maxVersion)`**（`:471-527`）；
// * 三个**真 HTTP 头**：`X-TMP-FILE` / `X-TYPE-NAME: SLICEUPLOAD` /
//   `X-FILE-CHUNK-END: "true"`（`:52-54,459-467`）；
// * ★ **续传探针**是**独立一次调用**：同样的头但
//   `X-FILE-CHUNK-END: "false"` + **`dummy` 假文件**参数
//   ⇒ 回 **`uploaded_size`**（`:454-466`）；
// * `path` = `id:<folderId>/<name>`、`type=file`、`conflict_action` 默认 **`version`**。
//
// ## 为什么这些必须被用例钉住（而不是"看着对就行"）
// 这三个头**不是表单字段**。发错地方（塞进 fields）服务端**不认**，
// 而表现是**普通上传成功** —— 也就是**静默走了错分支、续传从未生效**，
// 且**没有任何报错**。上一轮已确认：改之前
// `WebApiTransport.postMultipart` 连"自定义 HTTP 头"这条通道都没有，
// 所以那时**根本不可能实现续传**，本轮才补上（8 处：4 lib + 4 测试假传输）。
//
// ## 顺带钉住"能力位"（第 49 轮已落地）
// 官方 `is_support_recoverable_transfer` **不是服务端字段**，
// 而是本地由 `Files.maxVersion >= 9` 推出 —— 见
// `test/drive_recoverable_transfer_capability_test.dart`。
// 本文件测的是**协议本身**，两份用例互补。
//
// 全程打**内存 Mock Server**，不碰真机（规程 §5.1）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

late Directory _tmp;

Future<String> _dummyFile(String name, [String content = 'x']) async {
  final f = File('${_tmp.path}/$name');
  await f.writeAsString(content);
  return f.path;
}

void main() {
  late MockDsmBackend backend;
  late MockDsmTransport transport;
  late DsmWebApi web;
  late DriveApi drive;

  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('drive_chunk_');
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

  group('DU-1. ★★ `uploadChunk` 的三个真 HTTP 头必须出现在 **headers** 里', () {
    test('★★ X-TMP-FILE / X-TYPE-NAME / X-FILE-CHUNK-END=true 齐全', () async {
      final p = await _dummyFile('a.bin');
      await drive.uploadChunk(
        folderId: '973840842603147299',
        filePath: p,
        fileName: 'a.bin',
        taskId: 'task-123',
        offset: 0,
      );
      final h = transport.lastUpload!.headers;
      expect(h['X-TMP-FILE'], 'task-123', reason: '★ 断点续传的任务标识');
      expect(h['X-TYPE-NAME'], 'SLICEUPLOAD', reason: '★ 声明这是分片上传');
      expect(
        h['X-FILE-CHUNK-END'],
        'true',
        reason: '★ 续传那一次是 true；探针那一次必须是 false（见 DU-2）',
      );
    });

    test('★★ 这三个头**绝不能**出现在表单字段里（发错地方服务端不认）', () async {
      final p = await _dummyFile('b.bin');
      await drive.uploadChunk(
        folderId: '1',
        filePath: p,
        fileName: 'b.bin',
        taskId: 't',
        offset: 0,
      );
      final f = transport.lastUpload!.fields;
      for (final k in ['X-TMP-FILE', 'X-TYPE-NAME', 'X-FILE-CHUNK-END']) {
        expect(
          f.containsKey(k),
          isFalse,
          reason: '★ `$k` 是 HTTP 头，塞进 fields 等于没发（且会静默降级成普通上传）',
        );
      }
    });

    test('★ `path` 必须是 `id:<folderId>/<name>`（能写进团队文件夹的关键）', () async {
      final p = await _dummyFile('c.bin');
      await drive.uploadChunk(
        folderId: '973840842603147299',
        filePath: p,
        fileName: 'c.bin',
        taskId: 't',
        offset: 0,
      );
      expect(
        transport.lastUpload!.fields['path'],
        'id:973840842603147299/c.bin',
        reason: '★ 官方 computePathById(folderId) + "/" + name',
      );
    });

    test('★ 已经带 `id:` 前缀时**不再重复补**（防 `id:id:xxx`）', () async {
      final p = await _dummyFile('d.bin');
      await drive.uploadChunk(
        folderId: 'id:999',
        filePath: p,
        fileName: 'd.bin',
        taskId: 't',
        offset: 0,
      );
      expect(transport.lastUpload!.fields['path'], 'id:999/d.bin');
    });

    test(
      '★ `type=file` + `conflict_action` 官方默认 `version`（不是 autorename）',
      () async {
        final p = await _dummyFile('e.bin');
        await drive.uploadChunk(
          folderId: '1',
          filePath: p,
          fileName: 'e.bin',
          taskId: 't',
          offset: 0,
        );
        final f = transport.lastUpload!.fields;
        expect(f['type'], 'file');
        expect(
          f['conflict_action'],
          'version',
          reason:
              '★ 官方对**普通文件**默认 version（ApiSynoDriveFiles.java:492-499）；'
              '相机备份那条路才是 autorename，别混用',
        );
      },
    );

    test('★ 走的是 Drive 的 upload，**不是** FileStation', () async {
      final p = await _dummyFile('f.bin');
      await drive.uploadChunk(
        folderId: '1',
        filePath: p,
        fileName: 'f.bin',
        taskId: 't',
        offset: 0,
      );
      // ⚠️ 注意：`api`/`method`/`version` 是在 **fields** 里（与既有
      // `uploadPhotoForBackup` 一致）；`query` 只挂 `_sid`。
      // 第一次我把断言写在 query 上，拿到 null —— 是我测错了地方，不是代码错。
      final f = transport.lastUpload!.fields;
      expect(f['api'], 'SYNO.SynologyDrive.Files');
      expect(f['method'], 'upload');
    });

    test('★ 分片分支的版本是 `min(2, maxVersion)` —— 不是整文件那条的 8', () async {
      final p = await _dummyFile('g.bin');
      await drive.uploadChunk(
        folderId: '1',
        filePath: p,
        fileName: 'g.bin',
        taskId: 't',
        offset: 0,
      );
      final v = int.parse('${transport.lastUpload!.fields['version']}');
      expect(
        v,
        2,
        reason: '★ 官方 setAsUpload 的 offset>-1 分支是 Math.min(2, maxVersion)',
      );
    });

    test('★ 可选参数：mute / modified_time(秒) / sharing_token 按需发', () async {
      final p = await _dummyFile('h.bin');
      await drive.uploadChunk(
        folderId: '1',
        filePath: p,
        fileName: 'h.bin',
        taskId: 't',
        offset: 0,
        mute: true,
        modifiedTimeSeconds: 1700000000,
        sharingToken: 'tok',
      );
      final f = transport.lastUpload!.fields;
      expect(f['mute'], 'true');
      expect(f['modified_time'], '1700000000');
      expect(f['sharing_token'], 'tok');
    });

    test('★ 不发 mute / modified_time 时字段应缺席（不写死成 false/0）', () async {
      final p = await _dummyFile('i.bin');
      await drive.uploadChunk(
        folderId: '1',
        filePath: p,
        fileName: 'i.bin',
        taskId: 't',
        offset: 0,
      );
      final f = transport.lastUpload!.fields;
      expect(f.containsKey('mute'), isFalse);
      expect(f.containsKey('modified_time'), isFalse);
      expect(f.containsKey('sharing_token'), isFalse);
    });
  });

  group('DU-2. ★★★ `getUploadedSize`（续传探针）—— 与续传那次**只有一处不同**', () {
    test('★★★ `X-FILE-CHUNK-END` 必须是 **"false"**（探针）/ 续传是 "true"', () async {
      final p = await _dummyFile('probe.bin');
      await drive.getUploadedSize(
        taskId: 'task-777',
        dummyFilePath: p,
        dummyFileName: 'dummy',
      );
      final h = transport.lastUpload!.headers;
      expect(h['X-TMP-FILE'], 'task-777');
      expect(h['X-TYPE-NAME'], 'SLICEUPLOAD');
      expect(
        h['X-FILE-CHUNK-END'],
        'false',
        reason:
            '★★★ 这一条最容易抄错：探针是 false、真正续传是 true。'
            '抄成 true 就等于"我传完了"，服务端不会回已收字节',
      );
    });

    test('★★ 文件字段名必须是 **`dummy`**（官方 setAsGetUploadedSize 的假文件）', () async {
      final p = await _dummyFile('probe2.bin');
      await drive.getUploadedSize(
        taskId: 't',
        dummyFilePath: p,
        dummyFileName: 'dummy',
      );
      // MockDsmTransport 把 fileField 记进了 fields？不是——它记的是 files 表单；
      // 这里直接看传给 postMultipart 的 fileName 契约。
      expect(transport.lastUpload!.fileName, 'dummy');
    });

    test('★★ 回 `uploaded_size` ⇒ 解析成 int', () async {
      // ⚠️ `fixture` 的 builder 要返回**完整信封**（`{success,data}`），不是 data。
      backend.fixture(
        'SYNO.SynologyDrive.Files',
        'upload',
        (_) => {
          'success': true,
          'data': {'uploaded_size': 4096},
        },
      );
      final p = await _dummyFile('probe3.bin');
      final n = await drive.getUploadedSize(
        taskId: 't',
        dummyFilePath: p,
        dummyFileName: 'dummy',
      );
      expect(n, 4096);
    });

    test('★★ 服务端**没回** uploaded_size ⇒ 返回 0（保守：从头传，不跳到错误偏移）', () async {
      final p = await _dummyFile('probe4.bin');
      final n = await drive.getUploadedSize(
        taskId: 't',
        dummyFilePath: p,
        dummyFileName: 'dummy',
      );
      expect(n, 0, reason: '★ 猜一个偏移去续传会**写坏文件**；不确定就从头传');
    });
  });

  group('DU-2b. ★ `uploadFile`（整文件分支）—— 与分片分支的三处区别', () {
    test('★ 版本是 `Math.min(8, maxVersion)` = 8（分片那条是 2）', () async {
      final p = await _dummyFile('whole1.bin');
      await drive.uploadFile(
        folderId: '973840842603147299',
        filePath: p,
        fileName: 'whole1.bin',
      );
      expect(transport.lastUpload!.fields['version'], '8');
    });

    test('★★ 不带任何续传头（否则服务端会按分片处理）', () async {
      final p = await _dummyFile('whole2.bin');
      await drive.uploadFile(
        folderId: '1',
        filePath: p,
        fileName: 'whole2.bin',
      );
      final h = transport.lastUpload!.headers;
      expect(h['X-TMP-FILE'], isNull);
      expect(h['X-TYPE-NAME'], isNull);
      expect(h['X-FILE-CHUNK-END'], isNull);
    });

    test(
      '★ `path` 同样是 `id:<folderId>/<name>`、`conflict_action=version`',
      () async {
        final p = await _dummyFile('whole3.bin');
        await drive.uploadFile(
          folderId: 'id:77',
          filePath: p,
          fileName: 'whole3.bin',
        );
        final f = transport.lastUpload!.fields;
        expect(f['path'], 'id:77/whole3.bin');
        expect(f['type'], 'file');
        expect(f['conflict_action'], 'version');
      },
    );
  });

  group('DU-3. ★ 双请求闭环：探针 + 续传用同一个 taskId', () {
    test('★ 先问 uploaded_size，再带同一 taskId 续传 ⇒ 两次头一致（仅 END 不同）', () async {
      // ⚠️ `fixture` 的 builder 要返回**完整信封**（`{success,data}`），不是 data。
      backend.fixture(
        'SYNO.SynologyDrive.Files',
        'upload',
        (_) => {
          'success': true,
          'data': {'uploaded_size': 1024},
        },
      );
      final p = await _dummyFile('loop.bin');

      final already = await drive.getUploadedSize(
        taskId: 'same-task',
        dummyFilePath: p,
        dummyFileName: 'dummy',
      );
      final probeHeaders = Map<String, String>.from(
        transport.lastUpload!.headers,
      );

      await drive.uploadChunk(
        folderId: '1',
        filePath: p,
        fileName: 'loop.bin',
        taskId: 'same-task',
        offset: already,
      );
      final chunkHeaders = Map<String, String>.from(
        transport.lastUpload!.headers,
      );

      expect(already, 1024);
      expect(
        probeHeaders['X-TMP-FILE'],
        chunkHeaders['X-TMP-FILE'],
        reason: '★ 两次必须是同一个 taskId，否则服务端当两个任务',
      );
      expect(probeHeaders['X-TYPE-NAME'], chunkHeaders['X-TYPE-NAME']);
      expect(
        probeHeaders['X-FILE-CHUNK-END'],
        isNot(chunkHeaders['X-FILE-CHUNK-END']),
        reason: '★ 唯一的差异就是 END：探针 false / 续传 true',
      );
    });
  });
}
