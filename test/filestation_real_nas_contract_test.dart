// 「文件」模块 🟡 行的**真机契约验证**（第 26 轮）。
//
// ## 为什么这组用例才算"真机验证"
// 之前这些行标 🟡 的理由是"已实现，但只在离线 mock 里验过"。
// 单纯再跑一次离线用例**什么也证明不了** —— 那还是我方的猜想。
//
// 所以这里做的是：把**真机逐字回包**（`test/support/filestation_real_nas_samples.dart`，
// 只读 GET 抓的，字段一个没改）**喂给我方 DTO**，断言解析结果。
// 形状对不上就红。**这是"用真机验证"，不是"拿真机截图当证据"。**
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';

import 'support/filestation_real_nas_samples.dart';

/// 从真机回包里取 `data`（参数是已解析的 Map，不是字符串）。
Map<String, dynamic> asData(Map<String, dynamic> envelope) =>
    Map<String, dynamic>.from(envelope['data'] as Map);

void main() {
  group('R1. M04 分页（审计行 119）—— 真机契约', () {
    test('List/list 回包带 total / offset / files，且 files 是**扁平**在 data 下', () {
      final d = asData(realListWriteHome);
      expect(d['total'], isA<int>(), reason: '分页必须有 total');
      expect(d['offset'], isA<int>());
      expect(d['files'], isA<List>());
      // 真机实测：/home/Books 的 total=20，offset=0/limit=2 与 offset=2/limit=2
      // 返回**不同**的两项 ⇒ 服务端真的按 offset 切片（证据见文档）。
      expect(realListWriteHome['success'], isTrue, reason: '真机这次调用是成功的');
    });

    test('我方 DTO 能从真机回包解析出条目（含 path/name/isdir）', () {
      final files =
          (realListWriteHome['data'] as Map)['files'] as List<dynamic>;
      final e = FileEntryDto.fromJson(
        Map<String, dynamic>.from(files.first as Map),
      );
      expect(e.name, isNotEmpty);
      expect(e.path, startsWith('/home/'));
      expect(e.isDir, isTrue, reason: '/home 首项是目录（真机 isdir=true）');
    });
  });

  group('R2. M12 只读 / 无权限标识（审计行 127）—— 真机契约', () {
    test('★ 只读样本：perm.acl.write == false ⇒ 我方判定为只读', () {
      final files =
          (realListReadonlyDocker['data'] as Map)['files'] as List<dynamic>;
      final raw = Map<String, dynamic>.from(files.first as Map);
      // 先把真机原始值钉住（防"样本被改过"）。
      final acl = ((raw['additional'] as Map)['perm'] as Map)['acl'] as Map;
      expect(acl['write'], isFalse, reason: '这是 /docker 下的只读目录');

      final e = FileEntryDto.fromJson(raw);
      expect(e.permKnown, isTrue, reason: '真机给了 acl ⇒ 权限数据到位');
      expect(e.canWrite, isFalse);
      expect(e.isReadOnly, isTrue, reason: '★ 只读角标应当亮起');
    });

    test('可写对照样本：perm.acl.write == true ⇒ 不判只读', () {
      final files =
          (realListWriteHome['data'] as Map)['files'] as List<dynamic>;
      final raw = Map<String, dynamic>.from(files.first as Map);
      final acl = ((raw['additional'] as Map)['perm'] as Map)['acl'] as Map;
      expect(acl['write'], isTrue);

      final e = FileEntryDto.fromJson(raw);
      expect(e.canWrite, isTrue);
      expect(e.isReadOnly, isFalse, reason: '对照组不该被误判成只读');
    });

    test('★ 真机 perm 是 {acl,is_acl_mode,posix} —— 不是 can_write 之类的平铺字段', () {
      final files =
          (realListReadonlyDocker['data'] as Map)['files'] as List<dynamic>;
      final perm =
          (Map<String, dynamic>.from(files.first as Map)['additional']
                  as Map)['perm']
              as Map;
      expect(perm.keys.toSet(), {'acl', 'is_acl_mode', 'posix'});
      expect((perm['acl'] as Map).keys.toSet(), {
        'append',
        'del',
        'exec',
        'read',
        'write',
      });
      // ⚠️ 这一条是防"以后有人按直觉改成读 `can_write`"——
      // 真机上那个字段**不存在**，改了就会静默把只读判成可写。
      expect(perm.containsKey('can_write'), isFalse);
    });

    test('isdir 在**每项对象的顶层**，不在 additional 里（真机实测）', () {
      final files =
          (realListWriteHome['data'] as Map)['files'] as List<dynamic>;
      final raw = Map<String, dynamic>.from(files.first as Map);
      expect(raw.containsKey('isdir'), isTrue, reason: '顶层有 isdir');
      expect(
        (raw['additional'] as Map).containsKey('isdir'),
        isFalse,
        reason: 'additional 里**没有** isdir（我一开始就是在这里找错的）',
      );
      expect(raw['isdir'], isTrue);
    });
  });

  group('R3. M51 共享文件夹固定入口（审计行 190）—— 真机契约', () {
    test('list_share 回 {shares,total,offset}，真机这台有 docker/home', () {
      final d = asData(realListShare);
      expect(d['total'], 2);
      final shares = (d['shares'] as List)
          .map((s) => (s as Map)['name'])
          .toList();
      expect(shares, containsAll(['docker', 'home']));
    });

    test('每项是路径条目形状（name/path/isdir/additional.perm）', () {
      final shares = (asData(realListShare)['shares'] as List);
      final raw = Map<String, dynamic>.from(shares.first as Map);
      expect(raw['name'], isNotEmpty);
      expect(raw['path'], startsWith('/'));
      expect(raw['isdir'], isTrue);
      final e = FileEntryDto.fromJson(raw);
      expect(e.isDir, isTrue);
      expect(e.permKnown, isTrue, reason: 'list_share 也带 perm');
    });
  });

  group('R4. M36 / M58 / M50 —— 空集的形状（真机 0 条）', () {
    test('Sharing/list v3 → {links:[], offset, total}', () {
      final d = asData(realSharingList);
      expect(d['links'], isEmpty);
      expect(d['total'], 0);
      expect(d['offset'], 0);
      expect(realSharingList['success'], isTrue);
    });

    test('BackgroundTask/list v3 → {tasks:[], offset, total}', () {
      final d = asData(realBackgroundTaskList);
      expect(d['tasks'], isEmpty);
      expect(d['total'], 0);
      expect(d['offset'], 0);
      expect(realBackgroundTaskList['success'], isTrue);
    });

    test('Favorite/list v2 → {favorites:[], offset, total}', () {
      final d = asData(realFavoriteList);
      expect(d['favorites'], isEmpty);
      expect(d['total'], 0);
      expect(d['offset'], 0);
      expect(realFavoriteList['success'], isTrue);
    });

    test('★ 我方 DTO 能吃下这三个空集，不抛异常', () {
      // 空集是最容易漏测的形状：真机上"没有分享链接/没有后台任务/没收藏"
      // 恰恰是**最常见**的状态，而它跟"字段名写错"的表现一样（都是空）。
      expect(
        FileTaskListResult.fromJson(asData(realBackgroundTaskList)).tasks,
        isEmpty,
      );
    });
  });
}
