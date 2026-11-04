// **多套云端配置并存 + 快速切换**（接口层，离线）。
//
// 覆盖：
//   * 老版本单套配置的**迁移路径**（不能丢配置、不能丢安全存储里的 key）；
//   * 新建/另存/切换/重命名/删除；
//   * 同一厂商多套配置各自的 key 互不串台；
//   * 落库后冷启动能完整读回。
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/core/settings/cloud_key_store.dart';
import 'package:synhub/src/data/ai/cloud_provider.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/ai/cloud_settings.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider, chatStoreProvider;

ProviderContainer _container(ChatDatabase db, {CloudKeyStore? keys}) {
  return ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      cloudKeyStoreProvider.overrideWithValue(keys ?? MemoryCloudKeyStore()),
    ],
  );
}

void main() {
  group('老配置迁移（升级不丢配置、不丢 key）', () {
    test('单套老配置 → 第一套 profile，id 就是老 providerId', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MemoryCloudKeyStore();
      final c = _container(db, keys: store);
      addTearDown(c.dispose);

      // 老版本留下的 5 个 KV 键 + 安全存储里的 key 槽位
      final settings = SettingsService(c.read(chatStoreProvider));
      await settings.setAiCloudProviderId('deepseek');
      await settings.setAiCloudBaseUrl('https://api.deepseek.com/v1');
      await settings.setAiCloudProtocol('openai');
      await settings.setAiCloudModel('deepseek-reasoner');
      await settings.setAiCloudTemperature(0.3);
      await settings.setAiCloudMaxTokens(4096);
      await store.write('deepseek', 'sk-legacy-key');

      await c.read(cloudSettingsProvider.notifier).preload();

      final s = c.read(cloudSettingsProvider);
      expect(s.profiles, hasLength(1));
      expect(s.profiles.first.id, 'deepseek');
      expect(s.activeProfileId, 'deepseek');
      expect(s.providerId, 'deepseek');
      expect(s.model, 'deepseek-reasoner');
      expect(s.temperature, 0.3);
      expect(s.maxTokens, 4096);
      // key 从**老槽位**原样读回（没有要求用户重填）
      expect(s.apiKey, 'sk-legacy-key');
    });

    test('新装用户（老键全空）不造出空 profile', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      await c.read(cloudSettingsProvider.notifier).preload();
      final s = c.read(cloudSettingsProvider);
      expect(s.profiles, isEmpty);
      expect(s.activeProfileId, isEmpty);
      expect(s.configured, isFalse);
    });

    test('迁移出来的配置能继续新建：老配置 + 新配置并存', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      final settings = SettingsService(c.read(chatStoreProvider));
      await settings.setAiCloudProviderId('openai');
      await settings.setAiCloudBaseUrl('https://api.openai.com/v1');
      await settings.setAiCloudModel('gpt-4o-mini');
      final n = c.read(cloudSettingsProvider.notifier);
      await n.preload();
      final id = await n.saveProfileAsNew('公司中转');
      final s = c.read(cloudSettingsProvider);
      expect(s.profiles, hasLength(2));
      expect(s.profiles.map((p) => p.id).toSet(), {'openai', id});
      expect(s.activeProfileId, id);
    });
  });

  group('多套配置的增删改切换', () {
    test('selectProvider 幂等：同一厂商不会重复建配置', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);
      await n.selectProvider('openai');
      await n.setModel('gpt-4o-mini');
      await n.selectProvider('openai');
      expect(c.read(cloudSettingsProvider).profiles, hasLength(1));
      expect(c.read(cloudSettingsProvider).model, 'gpt-4o-mini');
    });

    test('同一家并存两套：另存为新配置后 active 切到新的、名字保留', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);
      await n.selectProvider('openai');
      await n.setModel('gpt-4o-mini');
      await n.saveProfileAsNew('公司中转');
      await n.setModel('gpt-4o');
      final id2 = await n.saveProfileAsNew('备用网关');
      final s = c.read(cloudSettingsProvider);
      expect(s.profiles, hasLength(3));
      expect(s.activeProfileId, id2);
      expect(s.model, 'gpt-4o');
      expect(s.profiles.firstWhere((p) => p.id == id2).displayName, '备用网关');
    });

    test('两套配置的 key 各自独立，来回切换互不串台', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MemoryCloudKeyStore();
      final c = _container(db, keys: store);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);

      await n.selectProvider('openai');
      await n.setBaseUrl('https://relay-a.example.com/v1');
      await n.setKey('sk-a');
      final idB = await n.saveProfileAsNew('B 套');
      await n.setBaseUrl('https://relay-b.example.com/v1');
      await n.setKey('sk-b');

      // 切回第一套：地址与 key 都是 A 的
      await n.switchProfile('openai');
      var s = c.read(cloudSettingsProvider);
      expect(s.baseUrl, 'https://relay-a.example.com/v1');
      expect(s.apiKey, 'sk-a');

      // 切到 B：拿到 B 的
      await n.switchProfile(idB);
      s = c.read(cloudSettingsProvider);
      expect(s.baseUrl, 'https://relay-b.example.com/v1');
      expect(s.apiKey, 'sk-b');

      // 安全存储里两个槽位都在
      expect(await store.read('openai'), 'sk-a');
      expect(await store.read(idB), 'sk-b');
    });

    test('切换会带出该套的全部字段（模型/温度/最大长度/协议）', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);
      await n.selectProvider('deepseek');
      await n.setModel('deepseek-reasoner');
      await n.setTemperature(1.1);
      await n.setMaxTokens(8192);
      await n.saveProfileAsNew('推理档');
      await n.selectProvider('gemini');
      await n.setModel('gemini-2.0-flash');

      final reasoningId = c
          .read(cloudSettingsProvider)
          .profiles
          .firstWhere((p) => p.displayName == '推理档')
          .id;
      await n.switchProfile(reasoningId);
      final s = c.read(cloudSettingsProvider);
      expect(s.providerId, 'deepseek');
      expect(s.model, 'deepseek-reasoner');
      expect(s.temperature, 1.1);
      expect(s.maxTokens, 8192);
      expect(s.protocol, CloudProtocol.openai);
    });

    test('重命名会落库（冷启动后名字还在）', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);
      await n.selectProvider('openai');
      final id = await n.saveProfileAsNew('临时');
      await n.renameProfile(id, '正式');
      expect(
        c
            .read(cloudSettingsProvider)
            .profiles
            .firstWhere((p) => p.id == id)
            .name,
        '正式',
      );

      final c2 = _container(db);
      addTearDown(c2.dispose);
      await c2.read(cloudSettingsProvider.notifier).preload();
      expect(
        c2
            .read(cloudSettingsProvider)
            .profiles
            .firstWhere((p) => p.id == id)
            .name,
        '正式',
      );
    });

    test('删除非当前配置：只少一套，当前不动', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);
      await n.selectProvider('openai');
      final idB = await n.saveProfileAsNew('B');
      await n.selectProvider('deepseek');
      await n.deleteProfile(idB);
      final s = c.read(cloudSettingsProvider);
      expect(s.profiles, hasLength(2));
      expect(s.activeProfileId, 'deepseek');
      expect(s.providerId, 'deepseek');
    });

    test('删除当前配置：自动切到剩下的第一套并载入它的字段与 key', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MemoryCloudKeyStore();
      final c = _container(db, keys: store);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);
      await n.selectProvider('openai');
      await n.setModel('gpt-4o-mini');
      await n.setKey('sk-openai');
      final idB = await n.saveProfileAsNew('B');
      await n.setBaseUrl('https://b.example.com/v1');
      await n.setKey('sk-b');

      await n.deleteProfile(idB);
      final s = c.read(cloudSettingsProvider);
      expect(s.profiles, hasLength(1));
      expect(s.activeProfileId, 'openai');
      expect(s.model, 'gpt-4o-mini');
      expect(s.apiKey, 'sk-openai');
      // 被删那套的 key 槽位也清掉了
      expect(await store.read(idB), isNull);
    });

    test('只剩一套时拒绝删除（并如实说明），状态不被打坏', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);
      await n.selectProvider('openai');
      await n.deleteProfile('openai');
      final s = c.read(cloudSettingsProvider);
      expect(s.profiles, hasLength(1));
      expect(s.error, isNotEmpty);
      expect(s.providerId, 'openai');
    });

    test('没选厂商就另存：拒绝并给提示，不新增空配置', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);
      final id = await n.saveProfileAsNew('空');
      expect(id, isEmpty);
      expect(c.read(cloudSettingsProvider).profiles, isEmpty);
      expect(c.read(cloudSettingsProvider).error, isNotEmpty);
    });

    test('冷启动读回：配置列表、当前 id、字段与 key 全对得上', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MemoryCloudKeyStore();
      final c = _container(db, keys: store);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);
      await n.selectProvider('openai');
      await n.setModel('gpt-4o-mini');
      await n.setKey('sk-openai');
      final idB = await n.saveProfileAsNew('B 套');
      await n.setBaseUrl('https://b.example.com/v1');
      await n.setModel('gpt-4o');
      await n.setTemperature(0.2);
      await n.setKey('sk-b');

      final c2 = _container(db, keys: store);
      addTearDown(c2.dispose);
      await c2.read(cloudSettingsProvider.notifier).preload();
      final s = c2.read(cloudSettingsProvider);
      expect(s.profiles, hasLength(2));
      expect(s.activeProfileId, idB);
      expect(s.baseUrl, 'https://b.example.com/v1');
      expect(s.model, 'gpt-4o');
      expect(s.temperature, 0.2);
      expect(s.apiKey, 'sk-b');
    });

    test('普通偏好表里不留 key（多套配置也一样）', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);
      await n.selectProvider('openai');
      await n.setKey('sk-secret-value');
      final settings = SettingsService(c.read(chatStoreProvider));
      expect(await settings.aiCloudProfiles(), isNot(contains('sk-')));
      expect(await settings.aiCloudActiveProfile(), isNot(contains('sk-')));
      expect(await settings.aiCloudBaseUrl(), isNot(contains('sk-')));
    });

    test('profileLabel：用户命名优先，否则回落厂商名', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);
      await n.selectProvider('zhipu');
      final s = c.read(cloudSettingsProvider);
      // 没命名 → 用厂商的中文名回落（界面 zh 时就是「智谱 GLM」）
      expect(n.profileLabel(s.profiles.first, AppTextZh()), '智谱 GLM');
      final id = await n.saveProfileAsNew('我的 GLM');
      final s2 = c.read(cloudSettingsProvider);
      expect(
        n.profileLabel(s2.profiles.firstWhere((p) => p.id == id), AppTextZh()),
        '我的 GLM',
      );
    });
  });
}
