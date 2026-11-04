// 推理引擎抽象 + 两个实现：
//   * [GemmaLlmEngine] —— 真的端侧模型（`flutter_gemma` + LiteRT-LM 引擎）；
//   * [ExtractiveLlmEngine] —— 纯 Dart 兜底（抽取式摘要/检索），一台手机都不用下载。
//
// 抽象的意义：**功能层（阅读器/笔记）只认 [LlmEngine]**。
// 于是：
//   * 单测里注入兜底引擎，整条 UI 链路可测，不碰原生；
//   * 没下模型/低配设备自动降级，功能不消失（UI 上如实标注是哪一档）。
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/i18n/l10n.dart';
import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';

import 'model_vault.dart';
import 'on_device_ai.dart';
import 'text_ai.dart';
import '../../core/user_facing_error.dart';

/// 引擎能力：能不能流式、有没有装模型
@immutable
class LlmStatus {
  const LlmStatus({
    required this.readiness,
    this.modelName = '',
    this.modelId = '',
    this.backend = '',
    this.detail = '',
  });

  const LlmStatus.unsupported(this.detail)
    : readiness = AiReadiness.unsupported,
      modelName = '',
      modelId = '',
      backend = '';

  final AiReadiness readiness;
  final String modelName;
  final String modelId;
  final String backend;
  final String detail;
}

/// 一次生成请求（引擎无关）
@immutable
class LlmPrompt {
  const LlmPrompt({
    required this.system,
    required this.user,
    this.maxOutputTokens = 512,
    this.temperature = 0.6,
    this.topK = 40,
  });

  final String system;
  final String user;
  final int maxOutputTokens;
  final double temperature;
  final int topK;
}

abstract class LlmEngine {
  /// 引擎档位（UI 标注用）
  AiEngineKind get kind;

  /// 现在是什么状态（装没装模型、能不能用）
  Future<LlmStatus> status();

  /// 流式生成（逐段回调；最后返回全文）
  Stream<String> generate(LlmPrompt prompt);

  /// 释放（模型很大，退出时要还内存）
  Future<void> dispose();
}

/// ---------------------------------------------------------------- 兜底引擎

/// 纯 Dart：不做生成，只做"抽取 + 检索"。
///
/// 对同样的 [AiRequest] 给出**结构相同**的答案（要点用 `- ` 开头，
/// `askBook` 带引用），所以上层 UI 只有一处分支（引擎标注）。
class ExtractiveLlmEngine implements LlmEngine {
  ExtractiveLlmEngine();

  @override
  AiEngineKind get kind => AiEngineKind.extractive;

  @override
  Future<LlmStatus> status() async => LlmStatus(
    readiness: AiReadiness.ready,
    modelName: currentText().aiExtractiveTitle,
    detail: currentText().aiExtractiveEngineDetail,
  );

  @override
  Stream<String> generate(LlmPrompt prompt) async* {
    // 兜底引擎是一次算完的：这里也走"流"，上层不用写两套
    final text = _answer(prompt.user);
    const chunk = 48;
    for (var i = 0; i < text.length; i += chunk) {
      final end = (i + chunk).clamp(0, text.length);
      yield text.substring(i, end);
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 兜底答案：从 prompt 里把原文捞出来再挑句子
  ///
  /// 这里**反解 prompt** 看着有点脏，但好处很实在：上层只拼一次 prompt，
  /// 两条引擎路径共用同一份输入，不会出现"模型看的是 A，兜底看的是 B"。
  String _answer(String userPrompt) {
    final body = _payload(userPrompt);
    if (userPrompt.contains('根据下面的原文片段回答问题')) {
      final question =
          RegExp(
            r'问题：(.*)$',
            dotAll: true,
          ).firstMatch(userPrompt)?.group(1)?.trim() ??
          '';
      final passages = userPrompt
          .split(RegExp(r'\n(?=\[\d+\])'))
          .where((s) => RegExp(r'^\[\d+\]').hasMatch(s.trim()))
          .toList();
      final ranked = rankPassages(question, [
        for (final p in passages)
          AiPassage(
            index: 0,
            title: p.split('\n').first,
            text: p.split('\n').skip(1).join('\n'),
          ),
      ], topK: 3);
      if (ranked.isEmpty) return currentText().aiExtractiveNotFound;
      final buf = StringBuffer(currentText().aiExtractivePassagesHeader);
      for (var i = 0; i < ranked.length; i++) {
        final one = collapseWhitespace(ranked[i].text).replaceAll('\n', ' ');
        buf.writeln(
          '- [${i + 1}] '
          '${one.length > 140 ? '${one.substring(0, 140)}…' : one}',
        );
      }
      return buf.toString().trim();
    }
    final bullets = extractiveSummary(body, maxBullets: 5);
    if (bullets.isEmpty) return currentText().aiExtractiveTooShort;
    return bullets.map((b) => '- $b').join('\n');
  }

  /// 把 prompt 里的"原文"部分抠出来：取最长的那个代码块/引用段
  String _payload(String prompt) {
    final idx = prompt.indexOf('\n\n');
    if (idx < 0) return prompt;
    var body = prompt.substring(idx + 2);
    // `askBook` 的片段是 `[1] 标题\n正文`，整段都当输入
    body = body.replaceAll(RegExp(r'^\[\d+\].*$', multiLine: true), '');
    return body.trim();
  }

  @override
  Future<void> dispose() async {}
}

/// ------------------------------------------------------------- 端侧模型引擎

/// `flutter_gemma` + LiteRT-LM。**只在真机上跑得起来**，单测永远走兜底。
class GemmaLlmEngine implements LlmEngine {
  GemmaLlmEngine({this.model});

  /// 用哪个档位的模型；null = 目录里的推荐档
  final AiModelInfo? model;

  bool _initialized = false;
  gemma.InferenceModel? _loaded;
  String _backend = '';

  AiModelInfo get modelInfo {
    final m = model;
    if (m != null) return m;
    for (final c in kOnDeviceModels) {
      if (c.recommended) return c;
    }
    return kOnDeviceModels.first;
  }

  @override
  AiEngineKind get kind => AiEngineKind.onDeviceModel;

  /// 初始化引擎（注册 LiteRT-LM）。失败就抛，由上层降级。
  Future<void> _ensureInit() async {
    if (_initialized) return;
    // `maxDownloadRetries`：手机网络抖，HF 断流是常事，重试几次比让用户重下强
    await gemma.FlutterGemma.initialize(
      inferenceEngines: [LiteRtLmEngine()],
      maxDownloadRetries: 8,
    );
    _initialized = true;
  }

  @override
  Future<LlmStatus> status() async {
    try {
      await _ensureInit();
      final installed = await gemma.FlutterGemma.listInstalledModels();
      if (installed.isEmpty) {
        return LlmStatus(
          readiness: AiReadiness.needsModel,
          detail: currentText().aiEngineReadyNoModel,
        );
      }
      final first = installed.first;
      final known = kOnDeviceModels.where(
        (m) => m.fileName == first || m.id == first,
      );
      return LlmStatus(
        readiness: AiReadiness.ready,
        modelName: known.isEmpty ? first : known.first.displayName,
        modelId: known.isEmpty ? '' : known.first.id,
        backend: _backend,
      );
    } catch (e) {
      // 原生引擎没起来（比如桌面/测试宿主）→ 说清楚，让上层用兜底
      return LlmStatus.unsupported(userFacingError(e));
    }
  }

  /// 下载并安装模型（带进度 0-100）
  ///
  /// 地址顺序：**先直连 Hugging Face，失败再走 hf-mirror 镜像**（国内网络
  /// 直连经常不通）。两条都失败才把错误抛给上层。
  Stream<int> install(AiModelInfo info) async* {
    await _ensureInit();

    // 收件箱（宿主机 `device_model_cache.sh restore` push 进来的）先搬进保管库，
    // 这样"卸载重装后要测端侧模型"这条路根本用不着网络。
    try {
      await ModelVault.importInbox();
    } catch (_) {
      // 收件箱不可用不影响正常下载
    }

    // ★★ 离线优先（用户 2026-09-25 要求：端侧模型很大，别反复下载）：
    // 保管库里已有这份模型 ⇒ 直接 `fromFile` 原地装载，**不发任何网络请求**。
    // 这条路覆盖"卸载重装/换构建后接着测"，是省流量的关键。
    if (await _installFromVault(info)) {
      yield kInstallFromVault;
      yield 100;
      return;
    }

    final urls = downloadUrlsOf(info);
    Object? lastError;
    for (var i = 0; i < urls.length; i++) {
      final controller = StreamController<int>();
      final viaMirror = i > 0;
      unawaited(() async {
        try {
          await gemma.FlutterGemma.installModel(
                modelType: gemma.ModelType.qwen3,
                fileType: gemma.ModelFileType.litertlm,
              )
              .fromNetwork(urls[i])
              .withProgress((p) => controller.add(viaMirror ? -p : p))
              .install();
          controller.add(100);
        } catch (e, st) {
          controller.addError(e, st);
        } finally {
          await controller.close();
        }
      }());
      var failed = false;
      await for (final p in controller.stream) {
        // 负数进度 = "正在走镜像"（UI 据此显示下载源）
        yield p;
      }
      // 走到这里说明这一轮结束了：检查一下到底装上了没
      if (!await _installed(info)) {
        failed = true;
        lastError ??= currentText().aiDownloadFailedShort;
      }
      if (!failed) {
        // ★ 下载成功立刻把这份文件收进离线保管库：
        //   以后再卸载重装（测试常态）就不用再花几百 MB 流量。
        await ModelVault.adopt(info);
        return;
      }
    }
    throw Exception(
      lastError?.toString() ?? currentText().aiDownloadFailedShort,
    );
  }

  /// 试着从离线保管库直接装载。成功返回 true。
  ///
  /// 失败（文件坏了/插件不认）会把这份缓存删掉并返回 false，让上层回落网络下载
  /// —— 坏缓存不能让用户卡在"装不上又下不了"。
  Future<bool> _installFromVault(AiModelInfo info) async {
    try {
      final cached = await ModelVault.find(info);
      if (cached == null) return false;
      await gemma.FlutterGemma.installModel(
            modelType: gemma.ModelType.qwen3,
            fileType: gemma.ModelFileType.litertlm,
          )
          .fromFile(cached.path)
          .install();
      if (await _installed(info)) return true;
      await ModelVault.forget(info);
      return false;
    } catch (_) {
      await ModelVault.forget(info);
      return false;
    }
  }

  /// 保管库里有没有这份模型的离线缓存（UI 用来打"重装免下载"徽标）。
  Future<bool> hasVaultCopy(AiModelInfo info) async {
    try {
      return await ModelVault.find(info) != null;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _installed(AiModelInfo info) async {
    try {
      final list = await gemma.FlutterGemma.listInstalledModels();
      return list.any((n) => n == info.fileName || n == info.id);
    } catch (_) {
      return false;
    }
  }

  /// 从引擎里卸载这个模型。
  ///
  /// ★ **故意不动离线保管库**：用户删模型多半只是"这个档位先不用了"，
  ///   而重下一份要几百 MB 流量。真要腾空间请显式调用 [purgeVault]。
  Future<void> uninstall(AiModelInfo info) async {
    await _ensureInit();
    await gemma.FlutterGemma.uninstallModel(info.fileName);
  }

  /// 连离线保管库一起清掉（用户显式要求"彻底删除"时才用），返回释放的字节数。
  Future<int> purgeVault() async => ModelVault.purge();

  /// 保管库位置（诊断/设置页展示）
  Future<String> vaultLocation() => ModelVault.locationLabel();

  /// 保管库里的模型清单
  Future<List<VaultEntry>> vaultEntries() => ModelVault.list();

  /// 把收件箱里的模型搬进保管库（模型页打开时调一次），返回搬进来的份数
  Future<int> importVaultInbox() async {
    try {
      return await ModelVault.importInbox();
    } catch (_) {
      return 0;
    }
  }

  /// 按文件名删（用于清理不在目录里的历史文件）
  Future<void> uninstallFile(String fileName) async {
    await _ensureInit();
    await gemma.FlutterGemma.uninstallModel(fileName);
  }

  /// 本机已装的模型文件名（判断"装没装"）
  Future<List<String>> installedFiles() async {
    try {
      await _ensureInit();
      return await gemma.FlutterGemma.listInstalledModels();
    } catch (_) {
      return const [];
    }
  }

  Future<gemma.InferenceModel> _model() async {
    final cached = _loaded;
    if (cached != null) return cached;
    await _ensureInit();
    final maxTokens = modelInfo.sizeBytes > 400 * 1000 * 1000 ? 4096 : 2048;
    final m = await gemma.FlutterGemma.getActiveModel(maxTokens: maxTokens);
    _loaded = m;
    _backend = m.activeBackend?.name ?? '';
    return m;
  }

  @override
  Stream<String> generate(LlmPrompt prompt) async* {
    final m = await _model();
    final session = await m.createSession(
      temperature: prompt.temperature,
      topK: prompt.topK,
      topP: 0.95,
      maxOutputTokens: prompt.maxOutputTokens,
      systemInstruction: prompt.system,
    );
    await session.addQueryChunk(
      gemma.Message.text(text: prompt.user, isUser: true),
    );
    await for (final chunk in session.getResponseAsync()) {
      yield chunk;
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await _loaded?.close();
    } catch (_) {
      // 关不掉也不该把退出流程卡住
    }
    _loaded = null;
  }
}
