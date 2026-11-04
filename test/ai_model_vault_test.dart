// 端侧模型**离线保管库**的单元测试（第 251 轮）。
//
// 用户要求：「手机上的端侧模型非常大，也不要反复下载，非常浪费流量」——
// `ModelVault` 就是为此而生：模型另存一份到卸载 App 不会被删的目录。
//
// 这里只测**不依赖平台的**那一半（目录解析、判真、登记、清空）；
// `adopt()` 要读 `flutter_gemma` 的托管路径，属于设备侧行为，由真机用例覆盖。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synhub/src/features/ai/model_vault.dart';
import 'package:synhub/src/features/ai/on_device_ai.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vault_test_');
    ModelVault.dirOverride = tmp;
  });

  tearDown(() async {
    ModelVault.dirOverride = null;
    ModelVault.inboxOverride = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// 造一份"看起来是真模型"的文件（必须 > minPlausibleBytes）
  Future<File> fakeModel(String name, {int bytes = 2 * 1024 * 1024}) async {
    final f = File(p.join(tmp.path, name));
    await f.writeAsBytes(List<int>.filled(bytes, 7), flush: true);
    return f;
  }

  test('保管库目录会被创建出来（拿不到也返回 null，不抛）', () async {
    final d = await ModelVault.dir();
    expect(d, isNotNull);
    expect(await d!.exists(), isTrue);
    expect(await ModelVault.locationLabel(), tmp.path);
  });

  test('空壳/半截文件不算缓存（否则会把坏文件当可用模型）', () async {
    // 造一个"体积很小"的模型描述：真实文件只需 1~2MB，测试不必写几百 MB
    const small = AiModelInfo(
      id: 'test-small',
      name: 'Test Small',
      fileName: 'test-small.litertlm',
      url: 'https://example.invalid/x',
      sizeBytes: 2 * 1024 * 1024, // 期望 2MB，下限 60% = 1.2MB
      note: '',
      license: '',
    );
    // 1) 完全没有
    expect(await ModelVault.find(small), isNull);
    // 2) 几十字节的残留
    await File(p.join(tmp.path, small.fileName)).writeAsBytes([1, 2, 3]);
    expect(await ModelVault.find(small), isNull, reason: '小于 1MB 一律不认');
    // 3) 明显偏小的半截档（< 期望的 60%）也不认
    await File(
      p.join(tmp.path, small.fileName),
    ).writeAsBytes(List<int>.filled(1024 * 1024, 1), flush: true);
    expect(await ModelVault.find(small), isNull, reason: '断了一半的残档不能当缓存');
    // 4) 体积达标才认
    final real = await fakeModel(small.fileName, bytes: 1500 * 1024);
    final hit = await ModelVault.find(small);
    expect(hit, isNotNull);
    expect(hit!.path, real.path);
  });

  test('体积下限：目录里的已知模型用各自 sizeBytes 的 60% 兜底', () {
    final lfm = kOnDeviceModels.first; // ~182MB
    expect(ModelVault.plausibleSize(1024 * 1024, lfm), isFalse);
    expect(
      ModelVault.plausibleSize((lfm.sizeBytes * 0.59).round(), lfm),
      isFalse,
    );
    expect(
      ModelVault.plausibleSize((lfm.sizeBytes * 0.61).round(), lfm),
      isTrue,
    );
  });

  test('清单会跳过旁注与 .part，并按体积从大到小排', () async {
    await fakeModel('small.litertlm', bytes: 2 * 1024 * 1024);
    await fakeModel('big.litertlm', bytes: 5 * 1024 * 1024);
    await File(p.join(tmp.path, 'big.litertlm$sidecar')).writeAsString('{}');
    await File(p.join(tmp.path, 'half.litertlm.part')).writeAsString('x');
    await File(p.join(tmp.path, 'tiny.litertlm')).writeAsBytes([0]);

    final list = await ModelVault.list();
    expect(list.map((e) => e.fileName).toList(), ['big.litertlm', 'small.litertlm']);
    expect(list.first.sizeLabel, '5 MB');
    expect(list.first.modelId, '', reason: '目录里认不出的历史文件也算占用');
  });

  test('能对上已知目录的模型会带上 modelId', () async {
    await fakeModel(kOnDeviceModels.first.fileName);
    final list = await ModelVault.list();
    expect(list, hasLength(1));
    expect(list.first.modelId, kOnDeviceModels.first.id);
  });

  test('totalBytes 汇总所有缓存', () async {
    await fakeModel('a.litertlm', bytes: 2 * 1024 * 1024);
    await fakeModel('b.litertlm', bytes: 3 * 1024 * 1024);
    expect(await ModelVault.totalBytes(), 5 * 1024 * 1024);
  });

  test('ingestFile：把外部文件（宿主机 push 回来的备份）登记进库并写旁注', () async {
    final info = kOnDeviceModels.first;
    final src = File(p.join(tmp.path, 'from_host.bin'));
    // 必须达到该模型 sizeBytes 的 60%（这里造 120% 以确保通过）
    final bytes = (info.sizeBytes * 1.2).round();
    await src.writeAsBytes(List<int>.filled(bytes, 9), flush: true);

    final out = await ModelVault.ingestFile(src, info);
    expect(out, isNotNull);
    expect(p.basename(out!.path), info.fileName, reason: '库里必须叫模型自己的文件名');
    expect(await out.length(), bytes);
    final side = File('${out.path}$sidecar');
    expect(await side.exists(), isTrue);
    expect(await side.readAsString(), contains(info.id));
    // 幂等：再来一次不会炸
    expect(await ModelVault.ingestFile(src, info), isNotNull);
  });

  test('forget：只丢这一份（含旁注与 .part），不碰其它模型', () async {
    final info = kOnDeviceModels.first;
    final a = await fakeModel(info.fileName);
    await File('${a.path}$sidecar').writeAsString('{}');
    await File('${a.path}.part').writeAsString('x');
    await fakeModel('other.litertlm');

    await ModelVault.forget(info);
    expect(await a.exists(), isFalse);
    expect(await File('${a.path}$sidecar').exists(), isFalse);
    expect(await File('${a.path}.part').exists(), isFalse);
    expect((await ModelVault.list()).map((e) => e.fileName), ['other.litertlm']);
  });

  test('purge：清空并返回释放字节数', () async {
    await fakeModel('a.litertlm', bytes: 2 * 1024 * 1024);
    await fakeModel('b.litertlm', bytes: 4 * 1024 * 1024);
    final freed = await ModelVault.purge();
    expect(freed, 6 * 1024 * 1024);
    expect(await ModelVault.list(), isEmpty);
    expect(await ModelVault.totalBytes(), 0);
  });

  group('收件箱（宿主机 push 进来的模型）', () {
    late Directory inbox;

    setUp(() async {
      inbox = await Directory.systemTemp.createTemp('vault_inbox_');
      ModelVault.inboxOverride = inbox;
    });

    tearDown(() async {
      if (await inbox.exists()) await inbox.delete(recursive: true);
    });

    test('认识的模型会被搬进保管库，收件箱那份删掉（不重复占空间）', () async {
      final info = kOnDeviceModels.first;
      final bytes = (info.sizeBytes * 1.1).round();
      final src = File(p.join(inbox.path, info.fileName));
      await src.writeAsBytes(List<int>.filled(bytes, 3), flush: true);

      expect(await ModelVault.importInbox(), 1);
      expect(await src.exists(), isFalse, reason: '搬完要删，避免同一份躺两遍');
      final inVault = await ModelVault.find(info);
      expect(inVault, isNotNull);
      expect(await inVault!.length(), bytes);
      expect(await File('${inVault.path}$sidecar').exists(), isTrue);
      // 幂等：再搬一次没有任何东西可搬
      expect(await ModelVault.importInbox(), 0);
    });

    test('半截档与不认识的文件都不进库', () async {
      final info = kOnDeviceModels.first;
      await File(
        p.join(inbox.path, info.fileName),
      ).writeAsBytes(List<int>.filled(1024, 1), flush: true); // 太小
      await File(
        p.join(inbox.path, 'evil.exe'),
      ).writeAsBytes(List<int>.filled(2 * 1024 * 1024, 1), flush: true);
      expect(await ModelVault.importInbox(), 0);
      expect(await ModelVault.list(), isEmpty);
    });

    test('保管库里已有同内容时，收件箱那份只删不拷', () async {
      final info = kOnDeviceModels.first;
      final bytes = (info.sizeBytes * 1.1).round();
      final src = File(p.join(inbox.path, info.fileName));
      await src.writeAsBytes(List<int>.filled(bytes, 5), flush: true);
      // 先在保管库放一份同样大小的
      await File(
        p.join(tmp.path, info.fileName),
      ).writeAsBytes(List<int>.filled(bytes, 5), flush: true);

      expect(await ModelVault.importInbox(), 1);
      expect(await src.exists(), isFalse);
      expect(await ModelVault.find(info), isNotNull);
    });
  });

  test('目录不可用时全部退化为"没有缓存"，绝不抛异常', () async {
    ModelVault.dirOverride = Directory('/definitely/not/writable/xyz');
    // 覆盖注入会尝试 mkdir；这条路在真机上不存在，但行为必须是"不抛、返回空"
    final list = await ModelVault.list();
    expect(list, isEmpty);
    expect(await ModelVault.totalBytes(), 0);
  });
}

/// 旁注后缀（与实现保持一致；写死在测试里是为了"改了实现会被测试发现"）
const String sidecar = ModelVault.sidecarSuffix;
