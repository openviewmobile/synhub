// ★ **③Drive 第 49 轮：D24「可续传上传」的能力位** —— 且**它不在服务端回包里**
//
// ## 这份用例钉的是什么
// D24（上传分片/断点续传）要动传输层，但在动之前必须先弄清**"什么时候该走续传"**。
// 官方 Synology Drive 3.9.0 的答案有点反直觉，值得单独钉住：
//
// 官方 DTO 上写着 `@SerializedName("is_support_recoverable_transfer")`
// （`/tmp/drive-apk/jadx/.../model/data/DriveServerInfo.java:83`），
// **看着像服务端给的字段，其实不是**。置位它的是
// `model/work/DriveServerInfoGetWork.java` 的 `onPrepareRequestWork` **case 6**：
//
// ```java
// if (apiManager.fetchAPI(ApiSynoDriveFiles.API_NAME).getMaxVersion() >= 9) {
//     this.mSupportRecoverableTransfer = true;
//     this.mSupportAppendText      = true;
// }
// ```
//
// 也就是**本地从 `SYNO.SynologyDrive.Files` 的 maxVersion 推**出来的，
// `@SerializedName` 只是算完之后缓存用的名字。
//
// ## 为什么必须写用例
// 判据写成"读某个回包字段"会**永远拿不到 true**（那个字段服务端根本不发），
// 于是续传路径**静默永不启用** —— 代码看着有、功能永远不生效，
// 且不会有任何报错。这类"安静失效"只能靠用例钉。
//
// ## 同阈值的兄弟能力（一并钉，防以后只改一个）
// `Files>=9` 官方**同一行**里还置位 `isSupportAppendText`，
// 所以两者阈值**必须一致**。
//
// 全程离线（内存 Mock / 假传输），不碰真机（规程 §5.1）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/chat_harness.dart' show FakeTransport;
import 'support/mock_dsm_transport.dart';

void main() {
  group('DC-1. ★ 真目录（Mock，Files maxVersion=11）⇒ 续传能力 = true', () {
    test(
      '★★ `Files` maxVersion>=9 ⇒ `isSupportRecoverableTransfer == true`',
      () async {
        final b = MockDsmBackend(catalog: DsmCatalog.load());
        b.login(username: 'demo_user', admin: false);
        final api = DsmWebApi(MockDsmTransport(b));
        await api.discover();

        final drive = DriveApi(api);
        expect(
          api.apiTable!['SYNO.SynologyDrive.Files']!.maxVersion,
          greaterThanOrEqualTo(9),
          reason: '前提：Mock 目录里 Files 的 maxVersion 本来就 >= 9（真机也是 v11）',
        );
        expect(
          drive.isSupportRecoverableTransfer,
          isTrue,
          reason: '★ 官方阈值正好是 >= 9（DriveServerInfoGetWork case 6）',
        );
      },
    );

    test('★ 同阈值的兄弟能力：追加文本也必须一起为 true', () async {
      final b = MockDsmBackend(catalog: DsmCatalog.load());
      b.login(username: 'demo_user', admin: false);
      final api = DsmWebApi(MockDsmTransport(b));
      await api.discover();
      final drive = DriveApi(api);

      expect(
        drive.isSupportAppendText,
        drive.isSupportRecoverableTransfer,
        reason: '★ 官方同一行里一起赋值 ⇒ 阈值必须一致，不能各写各的',
      );
    });
  });

  group('DC-2. ★★ 老服务器（Files maxVersion=8）⇒ 必须为 false（阈值边界）', () {
    /// 造一个只报到 v8 的目录。
    DsmWebApi apiWithFilesMax(int maxVersion) {
      final t = FakeTransport(
        {'SYNO.API.Info': {}},
        {
          'SYNO.SynologyDrive.Files': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': maxVersion,
          },
        },
      );
      return DsmWebApi(t);
    }

    test('★★ maxVersion=8 ⇒ false（差一档就不能走续传）', () async {
      final api = apiWithFilesMax(8);
      await api.discover();
      expect(
        DriveApi(api).isSupportRecoverableTransfer,
        isFalse,
        reason: '★ 官方是 `>= 9`；写成 `>= 8` 会在不支持的老服务端上走续传并失败',
      );
    });

    test('★ maxVersion=9 ⇒ true（下边界正好命中）', () async {
      final api = apiWithFilesMax(9);
      await api.discover();
      expect(DriveApi(api).isSupportRecoverableTransfer, isTrue);
    });

    test('★★ 目录为空（还没 discover）⇒ **false**，不能是 true', () async {
      final api = apiWithFilesMax(8); // 不 discover
      expect(
        DriveApi(api).isSupportRecoverableTransfer,
        isFalse,
        reason:
            '★ 对应官方 DTO 的默认值 `mIsSupportRecoverableTransfer = false`；'
            '若这里返回 true，未握手就会走续传',
      );
    });

    test('★ 目录里**没有 Files 这个 API** ⇒ false（不是崩）', () async {
      final t = FakeTransport({}, {
        'SYNO.Other': {'maxVersion': 99},
      });
      final api = DsmWebApi(t);
      await api.discover();
      expect(DriveApi(api).isSupportRecoverableTransfer, isFalse);
    });

    test('★★ 边界全扫：7→false, 8→false, 9→true, 10→true, 11→true', () async {
      for (final pair in [
        (7, false),
        (8, false),
        (9, true),
        (10, true),
        (11, true),
      ]) {
        final api = apiWithFilesMax(pair.$1);
        await api.discover();
        expect(
          DriveApi(api).isSupportRecoverableTransfer,
          pair.$2,
          reason: 'maxVersion=${pair.$1} 时官方判据是 >=9',
        );
      }
    });
  });
}
