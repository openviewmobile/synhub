// 图生图的**计价 / 额度 / 并发 / 配置**离线测试。
//
// 这一批要证明的四件事：
//   1. 单价未知就 `priced:false`，**不猜数字**；自建按 0 计；
//   2. 单日额度是**发起前的硬闸门**，变体数计入，跨日重置；
//   3. 并发上限 1（全局互斥）；
//   4. 设置默认值保守、key 只进安全存储、偏好表里没有 key。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/network_type.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/core/settings/cloud_key_store.dart';
import 'package:synhub/src/data/ai/cloud_pricing.dart';
import 'package:synhub/src/data/ai/image_edit_client.dart';
import 'package:synhub/src/data/ai/image_edit_pricing.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider, chatStoreProvider;
import 'package:synhub/src/features/photos/image_edit_preflight.dart';
import 'package:synhub/src/features/photos/image_edit_providers.dart';

ProviderContainer _container(ChatDatabase db, {CloudKeyStore? keys}) =>
    ProviderContainer(
      overrides: [
        chatDatabaseProvider.overrideWithValue(db),
        cloudKeyStoreProvider.overrideWithValue(keys ?? MemoryCloudKeyStore()),
      ],
    );

int _ms(DateTime d) => d.millisecondsSinceEpoch;

CloudUsageRecord _rec({
  required int atMs,
  required String kind,
  int images = 0,
}) => CloudUsageRecord(
  atMs: atMs,
  usage: CloudTokenUsage.zero,
  kind: kind,
  imageCount: images,
);

void main() {
  final day = DateTime(2026, 9, 1, 12);
  final now = _ms(day);

  group('按张计价：未知单价不猜（与 token 口径一致）', () {
    test('单价表当前**故意为空**，且取证日期为空串', () {
      expect(kImagePrices, isEmpty);
      expect(kImagePricingUpdatedAt, '');
      expect(imagePriceFor('gpt-image-1'), isNull);
    });

    test('云端认不出单价 → priced:false，usd 0（不计入合计）', () {
      final q = estimateImageCost(
        model: 'gpt-image-1',
        images: 3,
        baseUrl: 'https://api.openai.com/v1',
      );
      expect(q.priced, isFalse);
      expect(q.usd, 0);
    });

    test('自建/局域网 → priced:true, usd:0（复用 cloudIsLocalEndpoint）', () {
      for (final base in [
        'http://192.168.1.9:7860',
        'http://127.0.0.1:7860',
        'http://localhost:7860',
      ]) {
        final q = estimateImageCost(model: '', images: 4, baseUrl: base);
        expect(q.priced, isTrue, reason: base);
        expect(q.usd, 0, reason: base);
      }
    });

    test('张数为 0 或负数不产生负数费用', () {
      expect(
        estimateImageCost(
          model: 'x',
          images: 0,
          baseUrl: 'https://a.com',
        ).priced,
        isFalse,
      );
      expect(
        estimateImageCost(model: 'x', images: -3, baseUrl: 'https://a.com').usd,
        0,
      );
    });
  });

  group('单日额度：发起前拦、变体数计入、跨日重置', () {
    test('只统计当日 kind==photoAiEdit 的 imageCount', () {
      final records = [
        _rec(atMs: now, kind: kImageEditUsageKind, images: 2),
        _rec(atMs: now, kind: 'summary', images: 5),
        _rec(atMs: now - 86400000, kind: kImageEditUsageKind, images: 3),
      ];
      expect(imageEditImagesUsedOnDay(records, nowMs: now), 2);
      expect(
        imageEditImagesUsedOnDay(records, nowMs: now + 86400000),
        0,
        reason: '跨日重置',
      );
    });

    test('cap=3, used=2：出 1 张放行，出 2 张拦（变体数计入）', () {
      final records = [_rec(atMs: now, kind: kImageEditUsageKind, images: 2)];
      final q = imageEditQuota(records: records, nowMs: now, cap: 3);
      expect(q.used, 2);
      expect(q.remaining, 1);
      expect(q.blocks(1), isFalse);
      expect(q.blocks(2), isTrue);

      expect(
        imageEditQuotaBlock(records: records, nowMs: now, cap: 3, requested: 1),
        isNull,
      );
      expect(
        imageEditQuotaBlock(records: records, nowMs: now, cap: 3, requested: 2),
        ImageEditErrorKind.quotaExceeded,
      );
    });

    test('一次 n=4 直接吃掉 4 张额度', () {
      final records = [_rec(atMs: now, kind: kImageEditUsageKind, images: 4)];
      final q = imageEditQuota(records: records, nowMs: now, cap: 3);
      expect(q.used, 4);
      expect(q.exceeded, isTrue);
      expect(q.remaining, 0);
    });

    test('cap=0 → 功能关闭（不只是"超限"）', () {
      final q = imageEditQuota(records: const [], nowMs: now, cap: 0);
      expect(q.disabled, isTrue);
      expect(
        imageEditQuotaBlock(records: const [], nowMs: now, cap: 0),
        ImageEditErrorKind.disabled,
      );
    });

    test('单价未知也照样拦（额度按张数，不依赖价格可知）', () {
      final records = [_rec(atMs: now, kind: kImageEditUsageKind, images: 3)];
      expect(
        estimateImageCost(
          model: 'unknown-model',
          images: 1,
          baseUrl: 'https://api.openai.com/v1',
        ).priced,
        isFalse,
      );
      expect(
        imageEditQuotaBlock(records: records, nowMs: now, cap: 3),
        ImageEditErrorKind.quotaExceeded,
      );
    });

    test('额度文案带 x/y', () {
      final records = [_rec(atMs: now, kind: kImageEditUsageKind, images: 2)];
      final q = imageEditQuota(records: records, nowMs: now, cap: 3);
      expect(imageEditQuotaBlockText(q), contains('2/3'));
    });
  });

  group('并发上限 1：全局互斥', () {
    test('tryAcquire 第二次失败，release 后可再抢', () {
      final gate = ImageEditGate();
      expect(gate.inFlight, isFalse);
      expect(gate.tryAcquire(), isTrue);
      expect(gate.inFlight, isTrue);
      expect(gate.tryAcquire(), isFalse);
      gate.release();
      expect(gate.inFlight, isFalse);
      expect(gate.tryAcquire(), isTrue);
    });

    test('run 包一层：在途时第二个 run 抛 busy，且第一个跑完后锁释放', () async {
      final gate = ImageEditGate();
      final first = gate.run(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return 1;
      });
      await expectLater(
        gate.run(() async => 2),
        throwsA(
          isA<ImageEditException>().having(
            (e) => e.kind,
            'kind',
            ImageEditErrorKind.busy,
          ),
        ),
      );
      expect(await first, 1);
      expect(gate.inFlight, isFalse);
      expect(await gate.run(() async => 3), 3);
    });

    test('imageEditGateProvider 是全局单例', () {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      expect(
        identical(c.read(imageEditGateProvider), c.read(imageEditGateProvider)),
        isTrue,
      );
    });
  });

  group('CloudUsageRecord 追加 imageCount（容错解码，上限不变）', () {
    test('imageCount 进 JSON、能读回；老记录缺字段 → 0', () {
      final r = _rec(atMs: now, kind: kImageEditUsageKind, images: 3);
      final json = r.toJson();
      expect(json['images'], 3);
      final back = CloudUsageRecord.fromJson(jsonDecode(jsonEncode(json)));
      expect(back.imageCount, 3);

      final legacy = CloudUsageRecord.fromJson({
        'at': now,
        'kind': kImageEditUsageKind,
      });
      expect(legacy.imageCount, 0, reason: '向后兼容：缺字段不能崩');
    });

    test('encode/decode 整列表容错；上限仍是 500 条', () {
      final list = [
        for (var i = 0; i < 505; i++)
          _rec(atMs: now + i, kind: kImageEditUsageKind, images: 1),
      ];
      final trimmed = appendCloudUsage(const [], list.last);
      expect(trimmed.length, 1);
      var acc = <CloudUsageRecord>[];
      for (final r in list) {
        acc = appendCloudUsage(acc, r);
      }
      expect(acc.length, kCloudUsageMaxRecords);
      expect(acc.length, 500);
      expect(acc.first.atMs, now + 5, reason: '超限丢最旧的');

      final decoded = decodeCloudUsage(encodeCloudUsage(acc));
      expect(decoded.length, 500);
      expect(decoded.last.imageCount, 1);
    });
  });

  group('发起前门控（preflight）：每一条都返回确定类型', () {
    ImageEditErrorKind? run({
      bool enabled = true,
      bool consent = true,
      bool backendConfigured = true,
      bool keyPresent = true,
      NetworkType network = NetworkType.wifi,
      bool wifiOnly = true,
      bool allowMobile = false,
      List<CloudUsageRecord> records = const [],
      int cap = 3,
      int requested = 1,
    }) => imageEditPreflight(
      enabled: enabled,
      consent: consent,
      backendConfigured: backendConfigured,
      keyPresent: keyPresent,
      network: network,
      wifiOnly: wifiOnly,
      allowMobile: allowMobile,
      records: records,
      nowMs: now,
      dailyCap: cap,
      requestedImages: requested,
    );

    test('全满足 → 放行', () => expect(run(), isNull));
    test(
      '总开关关闭',
      () => expect(run(enabled: false), ImageEditErrorKind.disabled),
    );
    test(
      '后端未配置',
      () => expect(
        run(backendConfigured: false),
        ImageEditErrorKind.backendNotConfigured,
      ),
    );
    test(
      '未同意',
      () => expect(run(consent: false), ImageEditErrorKind.consentRequired),
    );
    test(
      '没有 key',
      () => expect(run(keyPresent: false), ImageEditErrorKind.missingKey),
    );
    test(
      '无网络',
      () =>
          expect(run(network: NetworkType.none), ImageEditErrorKind.noNetwork),
    );
    test(
      '仅 WiFi + 移动数据',
      () => expect(
        run(network: NetworkType.mobile),
        ImageEditErrorKind.wifiOnlyBlocked,
      ),
    );
    test(
      '仅 WiFi + 网络未知（保守）',
      () => expect(
        run(network: NetworkType.unknown),
        ImageEditErrorKind.networkUnknown,
      ),
    );
    test(
      '用户确认用流量 → 放行',
      () => expect(run(network: NetworkType.mobile, allowMobile: true), isNull),
    );
    test(
      '仅 WiFi 关闭 → 移动数据放行',
      () => expect(run(network: NetworkType.mobile, wifiOnly: false), isNull),
    );
    test('额度用尽', () {
      expect(
        run(
          records: [_rec(atMs: now, kind: kImageEditUsageKind, images: 3)],
        ),
        ImageEditErrorKind.quotaExceeded,
      );
    });
    test('请求 4 张但只剩 2 张 → 拦', () {
      expect(
        run(
          records: [_rec(atMs: now, kind: kImageEditUsageKind, images: 1)],
          cap: 3,
          requested: 4,
        ),
        ImageEditErrorKind.quotaExceeded,
      );
    });
  });

  group('设置键：默认保守 + key 只进安全存储', () {
    test('默认值：开关 false / 未同意 / 上限 3 / 仅 WiFi true / 后端空', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      final s = SettingsService(c.read(chatStoreProvider));

      expect(await s.imageEditEnabled(), isFalse);
      expect(await s.imageEditConsentV1(), isNull);
      expect(await s.imageEditDailyCap(), kImageEditDefaultDailyCap);
      expect(await s.imageEditDailyCap(), 3);
      expect(await s.imageEditWifiOnly(), isTrue);
      expect(await s.imageEditBackend(), isEmpty);
      expect(await s.imageEditBaseUrl(), isNull);
    });

    test('写入/读回；撤销同意是 DELETE 行 + 关总开关', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      final s = SettingsService(c.read(chatStoreProvider));

      await s.setImageEditEnabled(true);
      await s.setImageEditConsentV1('granted');
      await s.setImageEditDailyCap(5);
      await s.setImageEditWifiOnly(false);
      await s.setImageEditBackend('a1111_img2img');
      await s.setImageEditBaseUrl('http://192.168.1.9:7860');
      await s.setImageEditModel('');
      expect(await s.imageEditEnabled(), isTrue);
      expect(await s.imageEditConsentV1(), 'granted');
      expect(await s.imageEditDailyCap(), 5);
      expect(await s.imageEditWifiOnly(), isFalse);
      expect(await s.imageEditBackend(), 'a1111_img2img');

      await s.clearImageEditConsent();
      await s.setImageEditEnabled(false);
      expect(await s.imageEditConsentV1(), isNull);
      expect(await s.imageEditEnabled(), isFalse);
    });

    test('key 只在 CloudKeyStore；偏好表里搜不到 key 片段', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MemoryCloudKeyStore();
      final c = _container(db, keys: store);
      addTearDown(c.dispose);
      final s = SettingsService(c.read(chatStoreProvider));

      const key = 'sk-image-edit-super-secret';
      await store.write(SettingsService.kImageEditKeySlot, key);
      await s.setImageEditBackend('openai_images_edits');
      await s.setImageEditBaseUrl('https://api.example.com/v1');
      await s.setImageEditModel('gpt-image-1');

      // 偏好表整表扫一遍，任何 value 都不许含 key
      final rows = await db.select(db.keyValueRows).get();
      for (final row in rows) {
        expect(
          row.value.contains(key),
          isFalse,
          reason: '偏好表泄漏了 key: ${row.key}',
        );
      }
      // key 确实在安全存储里
      expect(await store.read(SettingsService.kImageEditKeySlot), key);
    });

    test('imageEditConfigProvider：后端/URL/模型来自偏好，key 来自安全存储', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MemoryCloudKeyStore();
      final c = _container(db, keys: store);
      addTearDown(c.dispose);
      final s = SettingsService(c.read(chatStoreProvider));

      expect(await c.read(imageEditConfigProvider.future), isNull);

      await s.setImageEditBackend('gemini_generate_content');
      await s.setImageEditBaseUrl('https://generativelanguage.example/v1beta');
      await s.setImageEditModel('gemini-2.5-flash');
      await store.write(SettingsService.kImageEditKeySlot, 'sk-abc');

      // FutureProvider 会缓存第一次的结果，配置变更后要显式失效
      c.invalidate(imageEditConfigProvider);
      final cfg = await c.read(imageEditConfigProvider.future);
      expect(cfg, isNotNull);
      expect(cfg!.backend, ImageEditBackend.geminiGenerateContent);
      expect(cfg.modelId, 'gemini-2.5-flash');
      expect(cfg.apiKey, 'sk-abc');
      expect(cfg.toString(), isNot(contains('sk-abc')));
    });

    test('provider 默认值与 set/preload 一致', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);

      expect(c.read(imageEditEnabledProvider), isFalse);
      expect(c.read(imageEditConsentProvider), isFalse);
      expect(c.read(imageEditDailyCapProvider), 3);
      expect(c.read(imageEditWifiOnlyProvider), isTrue);

      await c.read(imageEditEnabledProvider.notifier).set(true);
      await c.read(imageEditConsentProvider.notifier).grant();
      await c.read(imageEditDailyCapProvider.notifier).set(2);
      await c.read(imageEditWifiOnlyProvider.notifier).set(false);

      expect(c.read(imageEditEnabledProvider), isTrue);
      expect(c.read(imageEditConsentProvider), isTrue);
      expect(c.read(imageEditDailyCapProvider), 2);
      expect(c.read(imageEditWifiOnlyProvider), isFalse);

      await c.read(imageEditConsentProvider.notifier).revoke();
      expect(c.read(imageEditConsentProvider), isFalse);
      expect(c.read(imageEditEnabledProvider), isFalse);
    });
  });
}
