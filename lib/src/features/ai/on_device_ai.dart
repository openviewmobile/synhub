// 端侧 AI 的**公共类型与模型目录**（不依赖任何推理库，可离线单测）。
//
// 这个文件只放三样东西：
//   1. 我们要在端侧跑的模型目录（体积/来源/许可/推荐档位）；
//   2. "能不能用"的状态机（引擎没装 / 模型没下 / 可以用了）；
//   3. 任务的枚举与结果类型（答案 + 引用 + 用的是哪档引擎）。
//
// 为什么要这么拆：推理库（`flutter_gemma` + 引擎包）带着一堆原生依赖，
// 单测里跑不了，也不该跑。把"类型 + 目录 + 兜底算法"放在库外面，
// 整个功能在**没有模型**的时候也能用（抽取式摘要），测试也能钉住。
import 'package:flutter/foundation.dart';

import '../../core/device/device_capability.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';

/// 一个模型对硬件的**要求**（推荐/隐藏的判据，规则见 `ai_device_fit.dart`）。
///
/// 放在这个文件而不是 `ai_device_fit.dart`：目录（[AiModelInfo]）要引用它，
/// 而 fit 文件要引用目录，写在那边会互相 import。判据的**算法**仍在 fit 文件里。
@immutable
class AiModelRequirement {
  const AiModelRequirement({
    required this.minTier,
    required this.minRamBytesWithGpu,
    required this.minRamBytesWithoutGpu,
    this.requiresNpu = false,
    this.rationale = '',
  });

  /// 机器档位下限（档位已含内存/SoC/核数信息）。
  final DeviceComputeTier minTier;

  /// 有 GPU 计算后端（OpenCL）时的内存下限。
  final int minRamBytesWithGpu;

  /// **没有** GPU 计算后端（只能 CPU）时的内存下限 —— 通常更高。
  final int minRamBytesWithoutGpu;

  /// 是否必须 [NpuClass.vendorSpecific]（例：MT6993 专用变体）。
  final bool requiresNpu;

  /// 门槛依据（给人看的，写进文档/界面说明）。
  final String rationale;

  /// 按本机 GPU 情况取实际内存下限。
  int minRamBytesFor(DeviceCapability p) =>
      p.hasGpuCompute ? minRamBytesWithGpu : minRamBytesWithoutGpu;
}

/// 端侧 AI 能干的活（阅读器/笔记/文档共用一套）
enum AiTaskKind {
  /// 总结一章 / 一篇
  summary('summary', '总结'),

  /// 解释选中的一段（术语、论证、背景）
  explain('explain', '解释'),

  /// 翻译选中的一段
  translate('translate', '翻译'),

  /// 就着全文问问题（带引用）
  askBook('ask', '问这本书');

  const AiTaskKind(this.id, this.label);

  final String id;

  /// 中文标签（**回落**：无 context 的地方与老测试还用得上；界面走 [labelIn]）
  final String label;

  /// 本地化标签
  String labelIn(AppText t) => switch (this) {
    AiTaskKind.summary => t.aiTaskSummary,
    AiTaskKind.explain => t.aiTaskExplain,
    AiTaskKind.translate => t.aiTaskTranslate,
    AiTaskKind.askBook => t.aiTaskAskBook,
  };
}

/// 用哪一档引擎答的 —— UI 上必须**如实标注**，
/// 免得用户以为"内置摘要"就是模型写的。
enum AiEngineKind {
  /// 云端大模型（OpenAI 兼容 / Anthropic / Gemini，走 HTTP）
  cloud('cloud', '云端模型'),

  /// 端侧大模型（llama.cpp / LiteRT-LM 之类）
  onDeviceModel('model', '端侧模型'),

  /// 纯 Dart 的抽取式兜底（抽原句、拼要点，**不是生成**）
  extractive('extractive', '内置摘要（无模型）');

  const AiEngineKind(this.id, this.label);

  final String id;

  /// 中文标签（**回落**；界面走 [labelIn]）
  final String label;

  /// 本地化标签
  String labelIn(AppText t) => switch (this) {
    AiEngineKind.cloud => t.aiEngineCloud,
    AiEngineKind.onDeviceModel => t.aiEngineOnDevice,
    AiEngineKind.extractive => t.aiEngineExtractive,
  };
}

/// 端侧模型档位
class AiModelInfo {
  const AiModelInfo({
    required this.id,
    required this.name,
    required this.fileName,
    required this.url,
    required this.sizeBytes,
    required this.note,
    required this.license,
    this.recommended = false,
    this.needsAuth = false,
    this.requirement,
  });

  /// 稳定 id（存偏好用，改文案不影响已装记录）
  final String id;
  final String name;

  /// 本地化显示名（目录里的模型都是已知 id；认不出的回落 [name]）。
  ///
  /// 目录是 `const`，所以这里**不能**在构造期取译文，只能取用时查表
  /// （`dataText` 未装翻译器时回落中文原文）。
  String get displayName => switch (id) {
    'lfm25-230m-int4' => dataText('aiModelLfmName', 'LFM2.5 230M（int4）'),
    _ => name,
  };

  /// 落盘文件名（用来判断"装没装"）
  final String fileName;

  /// 下载地址（LiteRT-LM `.litertlm` 格式；HF 上 litert-community 组织）
  final String url;

  final int sizeBytes;

  /// 一句话说明（给用户看的取舍）
  final String note;

  /// 本地化说明（目录里的模型都是已知 id；认不出的回落 [note]）
  String noteIn(AppText t) => switch (id) {
    'lfm25-230m-int4' => t.aiNoteLfm,
    'qwen3-0.6b' => t.aiNoteQwen,
    _ => note,
  };

  /// 许可/来源链接
  final String license;

  final bool recommended;

  /// 需要 HuggingFace token（门控仓库）——我们选的都不需要
  final bool needsAuth;

  /// 硬件门槛（**端侧推荐必须按机器而异**，见 `ai_device_fit.dart`）。
  /// `null` = 用户自填 URL 的模型，不做判据。
  final AiModelRequirement? requirement;

  double get sizeGb => sizeBytes / (1024 * 1024 * 1024);

  String get sizeLabel => sizeBytes >= 1024 * 1024 * 1024
      ? '${sizeGb.toStringAsFixed(1)} GB'
      : '${(sizeBytes / (1024 * 1024)).round()} MB';
}

/// 端侧模型目录。
///
/// 只选 **LiteRT-LM（`.litertlm`）**：这个格式在 Android 上由 LiteRT-LM 引擎
/// 自己套 chat template，不用我们在 Dart 侧拼 prompt 模板（拼错就是输出乱码），
/// 跟 `flutter_gemma` 的 `FileType.litertlm` 一一对应。
///
/// 选择口径：
///   * 第一档 **LFM2.5 230M int4（~170MB）**：下载快、能装进任何中端机，
///     适合"先把管道跑通"和"低配设备也能用"；中文能力一般，指令跟随偏弱；
///   * 第二档 **Qwen3 0.6B（~586MB，推荐）**：中文好、支持思考模式，
///     0.6B 在 8GB 内存的机器上是"能跑得动且答得像话"的甜点档。
///
/// 更大的（Gemma 3n E2B int4 ~3GB）不放进默认目录：手机端发热/换页明显，
/// 用户真要可以自己在模型页填 URL。
const List<AiModelInfo> kOnDeviceModels = [
  AiModelInfo(
    id: 'lfm25-230m-int4',
    name: 'LFM2.5 230M（int4）',
    fileName: 'LFM2.5-230M_int4.litertlm',
    url:
        'https://huggingface.co/litert-community/LFM2.5-230M/resolve/main/'
        'LFM2.5-230M_int4.litertlm',
    // ★ 第 252 轮实测校正：HF 上游 API（`.../tree/main`）报的就是
    // 176756720 字节、LFS oid `a4683cdafbf7b0ae…`；本地文件 sha256 与之逐字符相同
    // （见 `~/synology_samples/device-models/SHA256SUMS`）。原先的 182000000
    // 是估值，偏大约 3% —— 既让卡片显示偏大，也把"半截档"下限放松了。
    sizeBytes: 176756720,
    note: '体积最小（约 170MB），装得进任何机器；中文一般，适合先跑通。',
    license: 'https://huggingface.co/litert-community/LFM2.5-230M',
    // 176.7MB / 230M 参数：官方卡在 Galaxy S26、Pixel 8a、iPhone 17 Pro 上
    // GPU 与 CPU 两条腿都实测可跑 ⇒ 内存门槛就取"模块下限"本身（3GB），
    // 即**能显示模块的机器就允许跑它**；GPU 委托有更好、没有也能跑。
    requirement: AiModelRequirement(
      minTier: DeviceComputeTier.entry,
      minRamBytesWithGpu: 3 * 1024 * 1024 * 1024,
      minRamBytesWithoutGpu: 3 * 1024 * 1024 * 1024,
      rationale: '官方卡实测 176.7MB，GPU/CPU 双后端在 Galaxy S26 · Pixel 8a 可跑',
    ),
  ),
  AiModelInfo(
    id: 'qwen3-0.6b',
    name: 'Qwen3 0.6B',
    // ⚠️ 文件名必须钉死成**这一份**转换：同一个 HF 仓库里还有
    // `Qwen3-0.6B.litertlm`（614MB）。实测那一份在真机上跑中文摘要时，
    // 每条要点的**头一两个字会变成 `Ġç®…` 这种乱码**（词表按字节解码的
    // 问题，字节还被吃掉了一部分，修不回来）。`mixed_int4` 是 Google
    // AI Edge Gallery 自己用的那份转换，中文输出干净。
    fileName: 'qwen3_0_6b_mixed_int4.litertlm',
    url:
        'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/'
        'qwen3_0_6b_mixed_int4.litertlm',
    // ★ 第 252 轮实测校正：上游就是 497516544 字节、LFS oid `7900eb4e7362d88c…`
    sizeBytes: 497516544,
    note: '推荐：中文好、答得像话，约 475MB，8GB 内存的机器跑得动。',
    license: 'https://huggingface.co/litert-community/Qwen3-0.6B',
    recommended: true,
    // 官方模型卡实测（`qwen3_0_6b_mixed_int4`，上下文 2048）：
    //   * GPU(OpenCL) 后端峰值私有内存 585MB ~ 1856MB（Samsung/vivo/TECNO 三台零售机）
    //   * CPU 后端峰值 **约 2.9GB**，且解码只有 8~13 tok/s
    // ⇒ 有 GPU 委托要 6GB；没有（只能 CPU）要 8GB。这不是"越保守越好"，
    //   而是"低于它就会 OOM 或被系统杀掉"——所以两个门槛要分开写。
    requirement: AiModelRequirement(
      minTier: DeviceComputeTier.mainstream,
      minRamBytesWithGpu: 6 * 1024 * 1024 * 1024,
      minRamBytesWithoutGpu: 8 * 1024 * 1024 * 1024,
      rationale: '官方卡实测：GPU 峰值 585MB~1.9GB；CPU 峰值约 2.9GB',
    ),
  ),
];

/// 国内网络直连 Hugging Face 经常不通，这里给出**镜像等价地址**。
///
/// 只做"域名替换"这一种改写（`huggingface.co` → `hf-mirror.com`，路径与
/// 校验完全一致），不引入第三方下载站；模型文件本身仍由 HF 生态的镜像分发。
/// 下载顺序：**先直连，失败再走镜像**——网络好时不额外绕路。
String mirrorUrlOf(String url) {
  const official = 'https://huggingface.co/';
  if (!url.startsWith(official)) return url;
  return 'https://hf-mirror.com/${url.substring(official.length)}';
}

/// `install()` 进度流里的**哨兵值**：这份模型是从**本地离线保管库**
/// （`ModelVault`，卸载 App 不会被删）直接装的，**一条网络请求都没有发**。
///
/// 负数区间的其它值沿用既有约定：`-1..-100` = 正在走 hf-mirror 镜像下载。
const int kInstallFromVault = -1000;

/// 该模型可用的下载地址（直连优先，镜像兜底；同一地址只出现一次）
List<String> downloadUrlsOf(AiModelInfo info) {
  final mirror = mirrorUrlOf(info.url);
  return mirror == info.url ? [info.url] : [info.url, mirror];
}

AiModelInfo? aiModelById(String? id) {
  if (id == null) return null;
  for (final m in kOnDeviceModels) {
    if (m.id == id) return m;
  }
  return null;
}

/// "端侧 AI 现在能不能用"——UI 全靠这个状态决定显示什么
enum AiReadiness {
  /// 这台设备/这个平台没接推理引擎（比如单测环境、Web）
  unsupported('这台设备不支持端侧推理'),

  /// 引擎在，但一个模型都没下
  needsModel('还没下载端侧模型'),

  /// 云端还没配好（没选厂商/没填模型）
  needsCloud('云端还没配置'),

  /// 模型在下载/安装中
  installing('正在安装模型'),

  /// 可以用了
  ready('模型就绪');

  const AiReadiness(this.label);

  /// 中文标签（**回落**；界面走 [labelIn]）
  final String label;

  /// 本地化标签
  String labelIn(AppText t) => switch (this) {
    AiReadiness.unsupported => t.aiReadinessUnsupported,
    AiReadiness.needsModel => t.aiReadinessNeedsModel,
    AiReadiness.needsCloud => t.aiReadinessNeedsCloud,
    AiReadiness.installing => t.aiReadinessInstalling,
    AiReadiness.ready => t.aiReadinessReady,
  };
}

/// 一次任务的输入：要处理的文本 + 上下文
@immutable
class AiRequest {
  const AiRequest({
    required this.kind,
    required this.text,
    this.title = '',
    this.question = '',
    this.contexts = const [],
    this.language = 'zh',
    this.maxOutputTokens = 512,
  });

  final AiTaskKind kind;

  /// 主体文本（选中段 / 本章正文）
  final String text;

  /// 出处（书名、章节名、笔记标题）——只用于拼 prompt 和展示，不落库
  final String title;

  /// `askBook` 的问题
  final String question;

  /// 检索出来的上下文片段（`askBook` 用）
  final List<AiPassage> contexts;

  final String language;
  final int maxOutputTokens;
}

/// 一段可引用的原文
@immutable
class AiPassage {
  const AiPassage({
    required this.index,
    required this.title,
    required this.text,
  });

  /// 章/节序号（引用角标用）
  final int index;
  final String title;
  final String text;
}

/// 一次任务的结果
@immutable
class AiAnswer {
  const AiAnswer({
    required this.text,
    required this.engine,
    required this.kind,
    this.passages = const [],
    this.elapsedMs = 0,
    this.modelName = '',
    this.truncated = false,
  });

  final String text;
  final AiEngineKind engine;
  final AiTaskKind kind;

  /// 检索用到的原文片段（`askBook` 的引用）
  final List<AiPassage> passages;

  final int elapsedMs;
  final String modelName;

  /// 输入太长被截断（必须告诉用户，不然"答得不对"会被赖到模型头上）
  final bool truncated;

  bool get isExtractive => engine == AiEngineKind.extractive;
}

/// 输入太长的上限（按字符粗算；0.6B 的 4K 上下文塞不下整本书）
const int kAiMaxInputChars = 6000;

/// 检索 top-k
const int kAiTopK = 3;
