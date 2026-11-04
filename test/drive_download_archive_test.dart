// ★★ **③Drive 第 55 轮：D25 多选打包下载**（`Files/download` 多文件）
//
// ## 缺口原文
// `D25 / :353 | 下载 | 🟠部分 | 实现：`drive_api.dart:373` 单文件直链 | 缺口：无多选打包 zip`
//
// ## 官方规格（不靠猜）
// `ApiSynoDriveFiles.setAsDownload`，`ApiSynoDriveFiles.java:388-408`：
// ```java
// version             = Math.min(7, api.getMaxVersion())
// files               = UtilsForApi.computeManyPathesById(fileIdList)
// force_download      = true
// update_access_time  = !downloadType.forSync()
// convert_office_file = true ^ downloadType.forSync()   // == !forSync()
// download_type       = downloadType.getValue()
// archive_name        = archiveName      // 仅非空
// ```
// `DownloadType`（`FileRepositoryNet.java:782`）：`DOWNLOAD("download")` /
// `PREVIEW("preview")` / `SYNC("sync")`，`forSync()` **仅 SYNC** 为真。
//
// ## ★ 本文件要钉的三类"安静出错"
// ① **版本**：`min(7,max)` 而不是单文件那条的 2 —— 发低了服务端**不认
//    `archive_name`**，于是"打包下载"变成"只下第一个文件"，且**不报错**；
// ② **`convert_office_file` 的方向**：官方写的是 `true ^ forSync`（异或），
//    普通下载必须是 **`true`**；写成 `false` 会拿到**未转换**的 Office 原文件
//    （对 `.odoc` 这类 Synology Office 文件意味着拿到压缩容器而不是 OOXML）；
// ③ **路径前缀**：`computePathById` 是"已以 `/` 开头就**不再加** `id:`"
//    —— 无脑加前缀会把 `/home/x` 变成 `id:/home/x`。
//
// 全程内存 Mock，不碰真机（规程 §5.1）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

void main() {
  late DsmWebApi web;
  late DriveApi drive;

  setUp(() async {
    final b = MockDsmBackend(catalog: DsmCatalog.load());
    b.login(username: 'demo_user', admin: false);
    web = DsmWebApi(MockDsmTransport(b));
    await web.discover();
    await web.login(account: 'demo_user', password: 'x');
    drive = DriveApi(web);
  });

  /// 把直链的 query 解成 map（同名键只保留最后一个）。
  Map<String, String> q(String url) => Uri.parse(url).queryParameters;

  group('DA-1. ★★ 多文件 `files` 是 JSON 数组，且每个都带 `id:`', () {
    test('★★ 两个 id ⇒ `["id:a","id:b"]`', () {
      final u = drive.downloadArchiveUrl(fileIds: ['a', 'b']);
      expect(
        q(u)['files'],
        '["id:a","id:b"]',
        reason:
            '★ 官方 `computeManyPathesById` 把列表逐项转成 `id:<id>`；'
            '只传一个或漏掉前缀，服务端就只会打包一个/报错',
      );
    });

    test('★ 单元素也要是**数组**（不是裸字符串）', () {
      final u = drive.downloadArchiveUrl(fileIds: ['x']);
      expect(q(u)['files'], '["id:x"]');
      expect(q(u)['files']!.startsWith('['), isTrue);
    });

    test('★★ 已是 `/` 开头的路径**不再加** `id:`（官方 computePathById 语义）', () {
      final u = drive.downloadArchiveUrl(fileIds: ['/home/team/a.txt', 'z']);
      expect(
        q(u)['files'],
        '["/home/team/a.txt","id:z"]',
        reason:
            '★ 官方是 `id.startsWith("/") ? id : "id:" + id`；'
            '无脑加前缀会得到 `id:/home/team/a.txt`，服务端找不到对象',
      );
    });
  });

  group('DA-2. ★★ 版本 / 打包参数（发错就"静默只下一个文件"）', () {
    test('★★ 版本是 7（官方 `Math.min(7,maxVersion)`），不是单文件那条的 2', () {
      final u = drive.downloadArchiveUrl(fileIds: ['a']);
      expect(
        q(u)['version'],
        '7',
        reason:
            '★ 发 2 的话服务端**不认 `archive_name`** ⇒ "打包下载"退化成'
            '"只下第一个文件"，而且**不报错**',
      );
    });

    test('★★ `convert_office_file` 必须是 `true`（官方 `true ^ forSync`）', () {
      final u = drive.downloadArchiveUrl(fileIds: ['a']);
      expect(
        q(u)['convert_office_file'],
        'true',
        reason:
            '★ 普通下载 forSync=false ⇒ true^false=true；'
            '写成 false 会拿到 Office 原文件（`.odoc` 会是压缩容器而非 OOXML）',
      );
      expect(q(u)['update_access_time'], 'true');
    });

    test('★ `force_download` / `download_type` 与官方一致', () {
      final u = drive.downloadArchiveUrl(fileIds: ['a']);
      expect(q(u)['force_download'], 'true');
      expect(q(u)['download_type'], 'download');
      expect(q(u)['method'], 'download');
      expect(q(u)['api'], 'SYNO.SynologyDrive.Files');
    });
  });

  group('DA-3. ★ 可选参数只在**非空**时出现', () {
    test('★ 不传 archiveName ⇒ query 里**没有** `archive_name`', () {
      final u = drive.downloadArchiveUrl(fileIds: ['a']);
      expect(
        q(u).containsKey('archive_name'),
        isFalse,
        reason:
            '★ 官方是 `if (!TextUtils.isEmpty(archiveName))`；'
            '空串发过去可能被当成"名字为空的压缩包"',
      );
    });

    test('★ 传了就出现', () {
      final u = drive.downloadArchiveUrl(fileIds: ['a'], archiveName: '打包.zip');
      expect(q(u)['archive_name'], '打包.zip');
    });

    test('★ `sharing_token` 同样只在非空时出现', () {
      expect(
        q(
          drive.downloadArchiveUrl(fileIds: ['a']),
        ).containsKey('sharing_token'),
        isFalse,
      );
      expect(
        q(
          drive.downloadArchiveUrl(fileIds: ['a'], sharingToken: 'tk'),
        )['sharing_token'],
        'tk',
      );
    });
  });

  group('DA-4. ★ 不破坏既有单文件路径', () {
    test('★ [downloadUrl] 仍是原来的形状（它已真机验证，不该被本次改动影响）', () {
      final u = drive.downloadUrl(fileId: 'a');
      // 单文件那条走 _v2，且带 is_preview
      expect(q(u)['files'], '["id:a"]');
      expect(q(u)['is_preview'], 'false');
      expect(
        q(u)['version'],
        '2',
        reason: '★ 故意保持 — 改了会让既有真机证据作废（第 53 轮教训，附录 AP.3）',
      );
    });
  });
}
