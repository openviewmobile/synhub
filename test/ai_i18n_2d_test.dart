// 批次 2d：`lib/src/data/ai/**` 的中文全部走 `dataText(key, 中文原文)`。
//
// 这里守两件事：
//   1. **对齐**：dataTextMap 里每个 ai* 键与 ARB 的 zh/en 值逐字一致；
//      两套 ARB 的键集合与顺序完全一致（只有 `@` 元数据键允许只在模板里）。
//   2. **切换**：zh/en 一切换，数据层文案（厂商名/备注/Key 提示/协议/错误）跟着变。
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/i18n/data_text.dart';
import 'package:synhub/src/data/ai/cloud_llm_client.dart';
import 'package:synhub/src/data/ai/cloud_provider.dart';

Map<String, String> _arb(String locale) {
  final raw = File('lib/l10n/app_$locale.arb').readAsStringSync();
  final map = jsonDecode(raw) as Map<String, dynamic>;
  return {
    for (final e in map.entries)
      if (!e.key.startsWith('@')) e.key: '${e.value}',
  };
}

/// `lib/src/data/ai/**` 里出现的翻译键（`ai_cloud_*` 是 KV 键，不算文案）
Set<String> _dataLayerKeys() {
  final out = <String>{};
  final dir = Directory('lib/src/data/ai');
  for (final f in dir.listSync().whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    final src = f.readAsStringSync();
    for (final m in RegExp(r"'(ai[A-Za-z0-9_]+)'").allMatches(src)) {
      final k = m.group(1)!;
      if (!k.startsWith('ai_cloud')) out.add(k);
    }
  }
  return out;
}

void main() {
  final zhArb = _arb('zh');
  final enArb = _arb('en');
  final zhMap = dataTextMap(AppTextZh());
  final enMap = dataTextMap(AppTextEn());

  group('批次 2d 对齐', () {
    test('两套 ARB：键集合与顺序完全一致（`@` 元数据除外）', () {
      final zhKeys = _arbOrder('zh');
      final enKeys = _arbOrder('en');
      expect(zhKeys, enKeys);
      expect(zhKeys.length, zhArb.length);
      expect(zhKeys.length, greaterThanOrEqualTo(2555));
    });

    test('dataTextMap 里每个 ai* 键都与 ARB 逐字一致（zh 与 en）', () {
      final aiKeys = zhMap.keys.where((k) => k.startsWith('ai')).toList();
      expect(aiKeys.length, greaterThanOrEqualTo(60));
      for (final k in aiKeys) {
        expect(zhMap[k], zhArb[k], reason: 'zh/$k');
        expect(enMap[k], enArb[k], reason: 'en/$k');
      }
    });

    test('`lib/src/data/ai/**` 用到的键：都在 dataTextMap 与两套 ARB 里', () {
      final used = _dataLayerKeys();
      expect(used, isNotEmpty);
      for (final k in used) {
        expect(zhMap.containsKey(k), isTrue, reason: 'dataTextMap 缺 $k');
        expect(zhArb.containsKey(k), isTrue, reason: 'app_zh.arb 缺 $k');
        expect(enArb.containsKey(k), isTrue, reason: 'app_en.arb 缺 $k');
      }
    });

    test('英文不再是中文（抽一批界面可见的）', () {
      for (final k in [
        'aiProvZhipuName',
        'aiProtoOpenai',
        'aiErrKeyInvalid',
        'aiErrNoStream',
        'aiCompleteSystemDefault',
        'aiModelPickerManual',
        'aiTruncatedNote',
        'aiCancelReason',
      ]) {
        expect(zhMap[k], isNot(enMap[k]), reason: k);
      }
    });
  });

  group('中英切换：数据层文案跟着走', () {
    tearDown(() => setCurrentText(AppTextZh()));

    test('厂商预设：名/备注/Key 提示', () {
      final p = cloudProviderById('zhipu')!;
      setCurrentText(AppTextZh());
      expect(p.nameText, '智谱 GLM');
      expect(p.keyHintText, '形如 id.secret');
      setCurrentText(AppTextEn());
      expect(p.nameText, 'Zhipu GLM');
      expect(p.keyHintText, 'Looks like id.secret');
      expect(p.noteText, isNot(zhArb['aiProvZhipuNote']));
    });

    test('协议名与模型选择提示', () {
      setCurrentText(AppTextZh());
      expect(CloudProtocol.openai.labelText, 'OpenAI 兼容');
      expect(
        modelPickerHint(cloudProviderById(kCustomProviderId)!),
        '直接手填模型 id',
      );
      setCurrentText(AppTextEn());
      expect(CloudProtocol.openai.labelText, 'OpenAI compatible');
      expect(
        modelPickerHint(cloudProviderById(kCustomProviderId)!),
        'Enter the model id by hand',
      );
    });

    test('HTTP 错误：英文且占位符都填了', () {
      setCurrentText(AppTextEn());
      final s = describeHttpError(401, '{"error":{"message":"bad key"}}');
      expect(s, contains('API key is invalid or expired (401)'));
      expect(s, contains('bad key'));
      expect(s, isNot(contains('{')));
      final e500 = describeHttpError(503, '');
      expect(e500, contains('Server error (503)'));
      final nf = describeHttpError(404, '', url: 'https://x/v1/chat');
      expect(nf, contains('check the base URL and model id'));
      expect(nf, contains('https://x/v1/chat'));
    });

    test('网络错误：英文且带主机名', () {
      setCurrentText(AppTextEn());
      final e = DioExceptionStub.timeout('https://api.example.com/v1');
      final s = describeDioError(e);
      expect(s, contains('api.example.com'));
      expect(s, contains('Connection timed out'));
    });

    test('中文回落与原中文逐字一致（老断言不受影响）', () {
      setCurrentText(AppTextZh());
      expect(
        dataText('aiErrNoStream', '服务端没有返回内容（可能这个模型不支持流式）'),
        zhArb['aiErrNoStream'],
      );
      expect(
        describeHttpError(401, '{"error":{"message":"x"}}'),
        'API Key 无效或已过期（401）：x',
      );
    });
  });
}

/// 按文件里的**出现顺序**取顶层键（JSON map 在 Dart 里保持插入顺序）
List<String> _arbOrder(String locale) {
  final raw = File('lib/l10n/app_$locale.arb').readAsStringSync();
  final map = jsonDecode(raw) as Map<String, dynamic>;
  return [
    for (final k in map.keys)
      if (!k.startsWith('@')) k,
  ];
}

/// 只为了造一个超时的 DioException（不联网）
class DioExceptionStub {
  static DioException timeout(String url) => DioException(
    requestOptions: RequestOptions(path: url),
    type: DioExceptionType.connectionTimeout,
  );
}
