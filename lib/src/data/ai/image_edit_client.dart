// 相册 AI 美化（图生图）的**三类后端客户端** —— 纯 Dart（数据层）。
//
// 三个后端，请求形态逐字对齐官方来源（见 `docs/photo-ai-image-to-image-plan.md` §4）：
//
//   * A1 `openAiImagesEdits`   —— `POST {base}/images/edits`，**multipart/form-data**。
//     字段名逐字：`image` / `prompt` / `n` / `size`（可选 `mask` / `quality` /
//     `response_format`，另加官方必填的 `model`）。
//     来源：openai-python `src/openai/types/image_edit_params.py`。
//     **结果恒按 base64 解析**（`data[].b64_json`）；`url` 一律不采信、不下载、
//     不落日志（§6.4 / §6.5）。
//   * A2 `geminiGenerateContent` —— `POST {base}/models/{model}:generateContent?key=…`，
//     JSON，图片走 `contents[0].parts[].inline_data = Blob{mime_type,data}`。
//     来源：googleapis `google/ai/generativelanguage/v1beta/content.proto`。
//     响应字段 REST 是 camelCase `inlineData`，proto 是 `inline_data` —— 因为
//     Q6 仍是【待取证】，这里**两种都认**（mimeType/mime_type 同样两种都认）。
//   * B1 `a1111Img2Img`      —— `POST {base}/sdapi/v1/img2img`，JSON，
//     `init_images` 用 **base64/data-URI**，强度走 `denoising_strength` 0.2/0.4/0.6。
//     来源：AUTOMATIC1111/stable-diffusion-webui `modules/api/api.py`。
//
// ⚠️ **安全硬规矩（B1）**：A1111 的 `decode_base64_to_image` **也接受 http(s) URL**
// （恶意配置的 endpoint 可借此让服务端去 fetch 任意地址）。我们**只发 base64/data-URI，
// 永不发 URL** —— 这一条在 [buildA1111Img2ImgBody] 里同时写成 `assert` 与运行时校验。
//
// ⚠️ **隐私硬规矩（全部错误/日志）**：错误信息只允许出现状态码、服务端 message
// （经 [sanitizeServerText] 洗过）、耗时、字节数、MIME、模型名。**禁止** base64 片段、
// 图片 URL、本地路径、提示词全文（提示词只记长度）。404 只显示**主机名**
// （Gemini 走 `?key=`，完整 URL 会泄漏 key）。
//
// 与 `cloud_pricing.dart` / `data_text.dart` 同一约束：**纯 Dart，不许 import flutter**。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import '../../core/net/traffic_meter.dart';
import 'package:image/image.dart' as img;

import '../../core/i18n/data_text.dart';
import 'cloud_pricing.dart' show cloudIsLocalEndpoint;
import 'cloud_provider.dart' show normalizeBaseUrl;
import 'image_edit_prompts.dart';

// --------------------------------------------------------------------- 后端

/// 三类后端（**Stability / ComfyUI 一律不做**：请求形态在方案 §11 里仍是待取证）
enum ImageEditBackend {
  openAiImagesEdits(
    'openai_images_edits',
    'OpenAI 兼容 · images/edits',
    'imageEditBackendOpenai',
  ),
  geminiGenerateContent(
    'gemini_generate_content',
    'Google Gemini · generateContent',
    'imageEditBackendGemini',
  ),
  a1111Img2Img(
    'a1111_img2img',
    'A1111 · sdapi/v1/img2img',
    'imageEditBackendA1111',
  );

  const ImageEditBackend(this.id, this.label, this.labelKey);

  final String id;

  /// 中文标签（**回落**；界面走 [labelText]）
  final String label;
  final String labelKey;

  String get labelText => dataText(labelKey, label);

  /// 这个后端要不要模型 id（A1111 不需要；它由 checkpoint 决定）
  bool get needsModel => this != ImageEditBackend.a1111Img2Img;

  /// 自建/局域网后端（成本按 0 计；允许没有 key）
  bool get isSelfHosted => this == ImageEditBackend.a1111Img2Img;

  static ImageEditBackend fromId(String? id) => switch (id) {
    'gemini_generate_content' => ImageEditBackend.geminiGenerateContent,
    'a1111_img2img' => ImageEditBackend.a1111Img2Img,
    _ => ImageEditBackend.openAiImagesEdits,
  };
}

// ------------------------------------------------------------------ 错误类型

/// 图生图的**确定错误类型**：每条对应方案 §8 降级表的一行（或一行的子分支）。
///
/// `textKey` / `zh` 是文案的 key 与中文原文（走 [dataText]，不改 `.arb` 也能先跑）。
/// 复用的 key（`aiErr*`）与 `cloud_llm_client.dart` 的既有文案**逐字一致**，
/// 没装翻译器时行为不变。
enum ImageEditErrorKind {
  // ---- 本地门控（发起前拦截；对应 §8 前 9 行 + §2.2 的 L1..L5）
  noNetwork('noNetwork', 'imgEditErrNoNetwork', '当前没有网络，无法使用 AI 美化'),
  networkUnknown(
    'networkUnknown',
    'imgEditErrNetworkUnknown',
    '当前网络类型未知，已按非 WiFi 保守处理',
  ),
  wifiOnlyBlocked(
    'wifiOnlyBlocked',
    'imgEditErrWifiOnly',
    '仅 WiFi 上传已开启；当前是移动数据，会消耗流量',
  ),
  backendNotConfigured(
    'backendNotConfigured',
    'imgEditErrNoBackend',
    '还没配置图生图后端，先去「AI 服务」里配好',
  ),
  missingKey('missingKey', 'imgEditErrNoKey', '还没填 API Key'),
  consentRequired(
    'consentRequired',
    'imgEditErrConsent',
    '需要先同意「照片会发送到你配置的服务」',
  ),
  disabled('disabled', 'imgEditErrDisabled', 'AI 美化已关闭'),
  quotaExceeded(
    'quotaExceeded',
    'imgEditErrQuota',
    '今日 AI 美化额度已用尽（{used}/{cap}），明日 00:00 恢复',
  ),
  busy('busy', 'imgEditErrBusy', '正在美化中，请稍候'),

  // ---- 请求参数
  promptTooLong(
    'promptTooLong',
    'imgEditErrPromptTooLong',
    '提示词太长（{chars} 字，上限 {limit} 字）',
  ),
  promptEmpty('promptEmpty', 'imgEditErrPromptEmpty', '先写一句想怎么美化'),

  // ---- HTTP 状态码（404 只给主机名；401/403/413/422/429/5xx 复用既有文案）
  requestRejected(
    'requestRejected',
    'imgEditErrRequestRejected',
    '该服务不接受这些参数或尺寸（400）{tail}',
  ),
  keyInvalid('keyInvalid', 'aiErrKeyInvalid', 'API Key 无效或已过期（401）{tail}'),
  noPermission('noPermission', 'aiErrNoPermission', '没有权限或被区域限制（403）{tail}'),
  insufficientBalance(
    'insufficientBalance',
    'aiErrInsufficientBalance',
    '余额不足（402）{tail}',
  ),
  notFound(
    'notFound',
    'imgEditErrNotFoundHost',
    '地址或模型不存在（404），检查「{host}」的地址与模型 id',
  ),
  bodyTooLarge('bodyTooLarge', 'aiErrBodyTooLarge', '请求体太大（413）{tail}'),
  paramsRejected('paramsRejected', 'aiErrParamsRejected', '参数不被接受（422）{tail}'),
  rateLimited('rateLimited', 'aiErrRateLimited', '触发限流或额度用尽（429），等一会儿再试{tail}'),
  serverError('serverError', 'aiErrServer', '服务端错误（{code}）{tail}'),
  requestFailed('requestFailed', 'aiErrRequestFailed', '请求失败（{code}）{tail}'),

  // ---- 网络层
  connectTimeout(
    'connectTimeout',
    'aiErrConnectTimeout',
    '连接超时：连不上 {host}（检查网络、代理或地址）',
  ),
  generateTimeout(
    'generateTimeout',
    'imgEditErrGenerateTimeout',
    '等生成太久没回数据（已 {seconds} 秒），可重试或改用更小尺寸',
  ),
  badCertificate(
    'badCertificate',
    'aiErrBadCertificate',
    '证书校验失败（自签名证书需要信任后才能连）',
  ),
  unreachable(
    'unreachable',
    'aiErrUnreachable',
    '连不上 {host}：网络不通或被拦截（国内直连国外服务通常需要代理）',
  ),
  localUnreachable(
    'localUnreachable',
    'imgEditErrLocalUnreachable',
    '连不上你的本地服务（{host}）',
  ),
  cancelledBilling(
    'cancelledBilling',
    'imgEditErrCancelledBilling',
    '已请求停止；服务端可能仍会计费',
  ),
  unknownNetwork('unknownNetwork', 'aiErrUnknown', '请求出错：{error}'),

  // ---- 响应体
  notJson('notJson', 'aiErrNotJson', '服务端返回的不是 JSON（可能被网关或登录页拦截了）：{error}'),
  serverErrorBody(
    'serverErrorBody',
    'imgEditErrServerBody',
    '服务端在响应里返回了错误：{tail}',
  ),
  contentBlocked(
    'contentBlocked',
    'imgEditErrBlocked',
    '服务拒绝生成这幅图（可能触发内容安全策略）{tail}',
  ),
  invalidImageResult(
    'invalidImageResult',
    'imgEditErrNotImage',
    '服务返回的数据不是图片，已丢弃（未保存任何内容）',
  ),
  emptyImageResult(
    'emptyImageResult',
    'imgEditErrEmptyImage',
    '服务返回的图片为空或被截断（未保存任何内容）',
  ),
  urlOnlyResult(
    'urlOnlyResult',
    'imgEditErrUrlOnly',
    '服务只返回了图片链接（本功能不接受链接，未保存任何内容）',
  ),
  partialVariants(
    'partialVariants',
    'imgEditErrPartial',
    '成功 {ok} 张，失败 {failed} 张（结果不完整）',
  ),

  // ---- 本地预检
  inputNotImage(
    'inputNotImage',
    'imgEditErrInputNotImage',
    '这张照片无法解码（可能不是图片或已损坏）',
  ),
  imageTooLarge(
    'imageTooLarge',
    'imgEditErrTooLarge',
    '照片过大（{mb} MB），上限约 {limit} MB',
  ),
  exifNotStripped(
    'exifNotStripped',
    'imgEditErrExifNotStripped',
    '内部错误：未能移除照片的 EXIF 信息（已阻止外发）',
  ),
  insecureUrlRefused(
    'insecureUrlRefused',
    'imgEditErrUrlRefused',
    '内部安全策略：只发 base64，不把图片链接发给自建后端',
  ),

  // ---- 保存回 NAS（批次② UI 用；本批只给确定类型与文案，不改 foto_api）
  saveForbidden105(
    'saveForbidden105',
    'imgEditErrSaveDenied',
    '没有权限保存到相册；已可保存到本机',
  ),
  uploadApiMissing(
    'uploadApiMissing',
    'imgEditErrUploadUnsupported',
    '这台 NAS 不支持从 App 上传照片',
  ),
  saveSessionExpired(
    'saveSessionExpired',
    'imgEditErrSessionExpired',
    '会话已过期，请重新登录',
  ),
  disabledMidFlight(
    'disabledMidFlight',
    'imgEditErrDisabledMidFlight',
    '已关闭 AI 美化；本次结果仍可保存',
  );

  const ImageEditErrorKind(this.id, this.textKey, this.zh);

  final String id;
  final String textKey;
  final String zh;
}

/// 占位符白名单：只有这些变量能进文案，杜绝把 URL / base64 顺手塞进来
const Set<String> kImageEditTextVars = {
  'tail',
  'code',
  'host',
  'used',
  'cap',
  'seconds',
  'ok',
  'failed',
  'chars',
  'limit',
  'mb',
  'error',
};

/// 按 [kind] 生成文案并填占位符（只认白名单里的变量）
String imageEditErrorText(
  ImageEditErrorKind kind, [
  Map<String, String> vars = const {},
]) {
  var s = dataText(kind.textKey, kind.zh);
  for (final e in vars.entries) {
    if (!kImageEditTextVars.contains(e.key)) continue;
    s = s.replaceAll('{${e.key}}', e.value);
  }
  return s;
}

/// 图生图专用的"说人话"异常（UI 只认它；`kind` 决定分支，`message` 给人看）
class ImageEditException implements Exception {
  ImageEditException(this.kind, [String? message])
    : message = message ?? imageEditErrorText(kind);

  final ImageEditErrorKind kind;
  final String message;

  @override
  String toString() => message;
}

// -------------------------------------------------------------- 文本消毒

/// 把服务端返回的错误正文**洗成人话**，再进文案。
///
/// 硬规矩：结果里**不得**出现 base64 片段、http(s) 链接、本地路径、提示词全文。
/// 做法：抽 message → 折叠空白 → 抹掉 [secrets]（key / 有效提示词）→
/// 抹掉链接与路径 → 抹掉超长 base64 串 → 截断 160 字。
String sanitizeServerText(
  Object? body, {
  List<String> secrets = const [],
  int max = 160,
}) {
  var text = _extractServerMessage(body);
  if (text.isEmpty) return '';
  // 折叠空白与控制字符
  text = text
      .replaceAll(RegExp(r'[\x00-\x1f]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  for (final s in secrets) {
    if (s.trim().isEmpty) continue;
    text = text.replaceAll(s, '***');
  }
  // 链接：连主机都不留（Gemini 的 ?key= 就在 URL 里）
  text = text.replaceAll(RegExp(r'https?://\S+'), '<链接已隐藏>');
  // 本地路径
  text = text.replaceAll(
    RegExp(r'/(?:Users|home|storage|data|var|private|tmp)/\S+'),
    '<路径已隐藏>',
  );
  // 超长 base64 串（≥120 个 base64 字符）
  text = text.replaceAll(RegExp(r'[A-Za-z0-9+/]{120,}={0,2}'), '<数据已隐藏>');
  if (text.length > max) text = '${text.substring(0, max)}…';
  return text;
}

String _extractServerMessage(Object? body) {
  if (body == null) return '';
  Object? parsed = body;
  if (body is String) {
    final t = body.trim();
    if (t.isEmpty) return '';
    try {
      parsed = jsonDecode(t);
    } catch (_) {
      return t;
    }
  }
  if (parsed is List<int>) {
    try {
      return utf8.decode(parsed, allowMalformed: true).trim();
    } catch (_) {
      return '';
    }
  }
  if (parsed is Map) {
    final m = parsed.map((k, v) => MapEntry('$k', v));
    final err = m['error'];
    if (err is String && err.trim().isNotEmpty) return err.trim();
    if (err is Map) {
      final em = err.map((k, v) => MapEntry('$k', v));
      for (final k in const ['message', 'msg', 'type', 'code']) {
        final v = em[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
    }
    final msg = m['message'] ?? m['msg'] ?? m['detail'];
    if (msg is String && msg.trim().isNotEmpty) return msg.trim();
  }
  return '';
}

/// 只保留 scheme/host/port/path，**丢掉 query 与 userInfo**
/// （Gemini 把 key 放在 `?key=`，整条 URL 不能进日志/文案）
String redactUrl(String raw) {
  final u = Uri.tryParse(raw.trim());
  if (u == null) return '';
  final port = u.hasPort ? ':${u.port}' : '';
  return '${u.scheme}://${u.host}$port${u.path}';
}

/// 从 base URL 里取主机名（404 文案只用它）
String imageEditHostOf(String raw) {
  final host = Uri.tryParse(raw.trim())?.host ?? '';
  return host;
}

// ------------------------------------------------------------------- 配置

/// 一次图生图的全部配置。
///
/// [toString] **不含 key，也不含 baseUrl 的查询串**（防 token 泄漏），
/// 提示词只记长度（提示词也是用户隐私）。
class ImageEditConfig {
  const ImageEditConfig({
    required this.backend,
    required this.baseUrl,
    this.apiKey = '',
    this.model = '',
    this.prompt = '',
    this.strength = ImageEditStrength.medium,
    this.variants = 1,
    this.size = 'auto',
    this.quality = '',
    this.width = 0,
    this.height = 0,
  });

  final ImageEditBackend backend;
  final String baseUrl;
  final String apiKey;
  final String model;
  final String prompt;
  final ImageEditStrength strength;

  /// 变体数（1..4；>1 张要计入单日额度）
  final int variants;

  /// A1 的 `size`（GPT image 认 `auto`/白名单；dall-e-2 只认正方形三档）
  final String size;

  /// A1 的 `quality`（空 = 不发这个字段，不替服务端猜）
  final String quality;

  /// B1 的 `width`/`height`（0 = 不发，让服务端用默认）
  final int width;
  final int height;

  String get modelId => model.trim();

  /// 规整后的变体数（1..4）
  int get variantCount => variants < 1 ? 1 : (variants > 4 ? 4 : variants);

  /// 有效提示词：强度前缀已改写（A1/A2 用；B1 的 prompt 也用它，只是强度另走参数）
  String get effectivePrompt => applyStrengthToPrompt(strength, prompt);

  /// 能不能发请求（base URL 是硬要求；需要模型的后端还要模型 id）
  bool get usable {
    if (normalizeBaseUrl(baseUrl).isEmpty) return false;
    if (backend.needsModel && modelId.isEmpty) return false;
    return true;
  }

  /// 敏感片段（错误消毒时要从服务端 message 里抹掉）
  List<String> get secrets => [
    if (apiKey.trim().isNotEmpty) apiKey.trim(),
    if (effectivePrompt.isNotEmpty) effectivePrompt,
  ];

  ImageEditConfig copyWith({
    ImageEditBackend? backend,
    String? baseUrl,
    String? apiKey,
    String? model,
    String? prompt,
    ImageEditStrength? strength,
    int? variants,
    String? size,
    String? quality,
    int? width,
    int? height,
  }) => ImageEditConfig(
    backend: backend ?? this.backend,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    prompt: prompt ?? this.prompt,
    strength: strength ?? this.strength,
    variants: variants ?? this.variants,
    size: size ?? this.size,
    quality: quality ?? this.quality,
    width: width ?? this.width,
    height: height ?? this.height,
  );

  /// 日志/诊断用：**绝不带 key，也不带查询串**；提示词只报长度
  @override
  String toString() =>
      'ImageEditConfig(${backend.id}, ${redactUrl(baseUrl)}, '
      'model=$modelId, key=${apiKey.isEmpty ? '无' : '有'}, '
      'strength=${strength.id}, variants=$variantCount, '
      'promptChars=${effectivePrompt.length})';
}

// --------------------------------------------------------------- 请求构造

/// 一个已构造好的 HTTP 请求（body 是 FormData（A1）或 Map（A2/B1））
class ImageEditHttpPlan {
  const ImageEditHttpPlan({
    required this.url,
    required this.headers,
    required this.body,
    required this.backend,
  });

  final Uri url;
  final Map<String, String> headers;

  /// A1: `FormData`；A2/B1: `Map<String, dynamic>`（由 client 自己 jsonEncode）
  final Object body;
  final ImageEditBackend backend;
}

/// A1 的 multipart 字段名（**逐字**，官方 `image_edit_params.py`）
const List<String> kOpenAiImageEditFieldNames = [
  'image',
  'prompt',
  'n',
  'size',
];

/// 构造 A1 的 multipart 表单。
///
/// 字段名逐字 `image` / `prompt` / `n` / `size`（可选 `quality` / `response_format`）；
/// `model` 也是官方必填，按 `image_edit_params.py` 带上（空则不发）。
FormData buildOpenAiEditForm(
  ImageEditConfig cfg,
  Uint8List imageBytes, {
  String fileName = 'image.jpg',
  String mimeType = 'image/jpeg',
}) {
  final form = FormData();
  form.files.add(
    MapEntry(
      'image',
      MultipartFile.fromBytes(
        imageBytes,
        filename: fileName,
        contentType: DioMediaType.parse(mimeType),
      ),
    ),
  );
  form.fields.add(MapEntry('prompt', cfg.effectivePrompt));
  form.fields.add(MapEntry('n', '${cfg.variantCount}'));
  form.fields.add(
    MapEntry('size', cfg.size.trim().isEmpty ? 'auto' : cfg.size.trim()),
  );
  if (cfg.modelId.isNotEmpty) form.fields.add(MapEntry('model', cfg.modelId));
  if (cfg.quality.trim().isNotEmpty) {
    form.fields.add(MapEntry('quality', cfg.quality.trim()));
  }
  // 恒按 base64 解析：显式请求 b64_json（GPT image 模型本来就恒返回 base64）
  form.fields.add(MapEntry('response_format', 'b64_json'));
  return form;
}

/// 构造 A2 的 JSON body：`contents[0].parts = [{text}, {inline_data: Blob}]`
Map<String, dynamic> buildGeminiEditBody(
  ImageEditConfig cfg,
  Uint8List imageBytes, {
  String mimeType = 'image/jpeg',
}) {
  return {
    'contents': [
      {
        'role': 'user',
        'parts': [
          {'text': cfg.effectivePrompt},
          {
            'inline_data': {
              'mime_type': mimeType,
              'data': base64Encode(imageBytes),
            },
          },
        ],
      },
    ],
    // Q6【待取证】：出图是否需要显式 responseModalities 尚未拿到官方原文。
    // 先按"要求返回图片"发送；解析端两种字段名都认，所以这里不影响健壮性。
    'generationConfig': {
      'responseModalities': ['TEXT', 'IMAGE'],
    },
  };
}

/// 构造 B1 的 JSON body：`init_images` 用 **base64/data-URI**。
///
/// ⚠️ 只发 base64/data-URI，**永不发 URL**（A1111 的 `decode_base64_to_image`
/// 会接受 http(s) URL，我们不主动用这个能力）。这一条是 `assert` + 运行时双保险。
Map<String, dynamic> buildA1111Img2ImgBody(
  ImageEditConfig cfg,
  Uint8List imageBytes, {
  String mimeType = 'image/jpeg',
}) {
  final dataUri = 'data:$mimeType;base64,${base64Encode(imageBytes)}';
  final initImages = <String>[dataUri];
  _refuseUrlInitImages(initImages);
  final body = <String, dynamic>{
    'init_images': initImages,
    'prompt': cfg.effectivePrompt,
    'denoising_strength': cfg.strength.denoising,
    // Q9【待取证】：一次出多张用 batch_size / n_iter 尚未拿到官方原文；
    // 这里用 A1111 最常见的 batch_size，n_iter 固定 1。
    'batch_size': cfg.variantCount,
    'n_iter': 1,
  };
  if (cfg.width > 0 && cfg.height > 0) {
    body['width'] = cfg.width;
    body['height'] = cfg.height;
  }
  return body;
}

/// 安全硬规矩的落点：`init_images` 里**任何一项**以 http(s) 开头都拒绝。
void _refuseUrlInitImages(List<String> initImages) {
  assert(
    initImages.every((e) => !_looksLikeUrl(e)),
    '安全策略：A1111 init_images 只允许 base64/data-URI，禁止 URL',
  );
  for (final e in initImages) {
    if (_looksLikeUrl(e)) {
      throw ImageEditException(ImageEditErrorKind.insecureUrlRefused);
    }
  }
}

bool _looksLikeUrl(String v) {
  final t = v.trimLeft().toLowerCase();
  return t.startsWith('http://') || t.startsWith('https://');
}

/// 构造完整请求（URL + 头 + body）。测试可直接检查字段名与 URL 形态。
ImageEditHttpPlan buildImageEditPlan(
  ImageEditConfig cfg,
  Uint8List imageBytes, {
  String fileName = 'image.jpg',
  String mimeType = 'image/jpeg',
}) {
  final base = normalizeBaseUrl(cfg.baseUrl);
  return switch (cfg.backend) {
    ImageEditBackend.openAiImagesEdits => ImageEditHttpPlan(
      url: Uri.parse('$base/images/edits'),
      // Content-Type 由 dio 的 FormData 自己带 boundary，不能手写
      headers: {'Authorization': 'Bearer ${_bearerKey(cfg)}'},
      body: buildOpenAiEditForm(
        cfg,
        imageBytes,
        fileName: fileName,
        mimeType: mimeType,
      ),
      backend: cfg.backend,
    ),
    ImageEditBackend.geminiGenerateContent => ImageEditHttpPlan(
      url: Uri.parse(
        '$base/models/${Uri.encodeComponent(cfg.modelId)}:generateContent'
        '?key=${Uri.encodeQueryComponent(cfg.apiKey)}',
      ),
      headers: const {'Content-Type': 'application/json'},
      body: buildGeminiEditBody(cfg, imageBytes, mimeType: mimeType),
      backend: cfg.backend,
    ),
    ImageEditBackend.a1111Img2Img => ImageEditHttpPlan(
      url: Uri.parse('$base/sdapi/v1/img2img'),
      headers: {
        'Content-Type': 'application/json',
        // A1111 默认无鉴权（`--api-auth` 才有 Basic，Q10 待取证）；
        // 有 key 时按业界网关惯例发 Bearer，没有就不发这个头。
        if (cfg.apiKey.trim().isNotEmpty)
          'Authorization': 'Bearer ${cfg.apiKey.trim()}',
      },
      body: buildA1111Img2ImgBody(cfg, imageBytes, mimeType: mimeType),
      backend: cfg.backend,
    ),
  };
}

String _bearerKey(ImageEditConfig cfg) =>
    cfg.apiKey.trim().isEmpty ? 'not-needed' : cfg.apiKey.trim();

// --------------------------------------------------------------- 响应解析

/// 一次图生图的结果。
///
/// `images` 是**已校验为合法图片**的字节（校验失败的一张都不收）；
/// `failed` 是请求了但拿回非法/空数据的张数 —— **部分成功就报部分成功**。
class ImageEditOutcome {
  const ImageEditOutcome({
    required this.images,
    required this.requested,
    this.failed = 0,
    this.urlOnly = false,
  });

  final List<Uint8List> images;
  final int requested;
  final int failed;

  /// 服务端只给了 URL（我们**不下载 URL**，一律判失败）
  final bool urlOnly;

  bool get ok => images.isNotEmpty && failed == 0;

  bool get partial => images.isNotEmpty && failed > 0;

  int get okCount => images.length;

  /// 有失败时给 UI 的警告类型（部分成功 / 只有链接）
  ImageEditErrorKind? get warningKind {
    if (failed == 0) return null;
    return urlOnly
        ? ImageEditErrorKind.urlOnlyResult
        : ImageEditErrorKind.partialVariants;
  }

  String warningText() {
    final k = warningKind;
    if (k == null) return '';
    return imageEditErrorText(k, {'ok': '$okCount', 'failed': '$failed'});
  }
}

/// 校验一段字节是不是**能解码的图片**（`image_prepare.dart:63-69` 同法）
bool isValidImageBytes(Uint8List bytes) {
  if (bytes.isEmpty) return false;
  try {
    final decoded = img.decodeImage(bytes);
    return decoded != null && decoded.width > 0 && decoded.height > 0;
  } catch (_) {
    return false;
  }
}

/// 把 base64（允许 `data:...;base64,` 前缀）解成图片字节；不合法就抛确定的错误。
Uint8List decodeImageBase64(String raw) {
  var s = raw.trim();
  if (s.isEmpty) {
    throw ImageEditException(ImageEditErrorKind.emptyImageResult);
  }
  final comma = s.indexOf(',');
  if (s.toLowerCase().startsWith('data:') && comma > 0) {
    s = s.substring(comma + 1).trim();
  }
  Uint8List bytes;
  try {
    bytes = base64Decode(s);
  } catch (_) {
    throw ImageEditException(ImageEditErrorKind.invalidImageResult);
  }
  if (bytes.isEmpty) {
    throw ImageEditException(ImageEditErrorKind.emptyImageResult);
  }
  if (!isValidImageBytes(bytes)) {
    throw ImageEditException(ImageEditErrorKind.invalidImageResult);
  }
  return bytes;
}

/// A1 响应：`{"data":[{"b64_json":"…"} …]}` —— **恒按 base64 解析**。
///
/// `url` 字段不采信：只记 `urlOnly`，绝不下载/保存/打日志（§6.4）。
ImageEditOutcome parseOpenAiEditResponse(
  Object? raw, {
  required int requested,
}) {
  final m = _asMap(raw);
  final errKind = _bodyError(raw);
  if (errKind != null) throw errKind;
  final data = m['data'];
  if (data is! List || data.isEmpty) {
    throw ImageEditException(ImageEditErrorKind.invalidImageResult);
  }
  final images = <Uint8List>[];
  var failed = 0;
  var urlOnly = false;
  var lastInvalid = ImageEditErrorKind.invalidImageResult;
  for (final one in data) {
    final e = _asMap(one);
    final b64 = e['b64_json'] ?? e['b64Json'];
    if (b64 is String) {
      try {
        images.add(decodeImageBase64(b64));
        continue;
      } on ImageEditException catch (ex) {
        lastInvalid = ex.kind;
        failed++;
        continue;
      }
    }
    // 只有 URL：不采信
    final url = e['url'];
    if (url is String && url.trim().isNotEmpty) {
      urlOnly = true;
      failed++;
      continue;
    }
    failed++;
  }
  if (images.isEmpty) {
    if (urlOnly) throw ImageEditException(ImageEditErrorKind.urlOnlyResult);
    throw ImageEditException(lastInvalid);
  }
  return ImageEditOutcome(
    images: images,
    requested: requested,
    failed: failed,
    urlOnly: urlOnly,
  );
}

/// A2 响应：出图在 `candidates[].content.parts[].inlineData`（camelCase）
/// 或 `inline_data`（proto 原名）—— **两种都认**（Q6 待取证，第 ⑨ 项）。
ImageEditOutcome parseGeminiEditResponse(
  Object? raw, {
  required int requested,
}) {
  final errKind = _bodyError(raw);
  if (errKind != null) throw errKind;
  final m = _asMap(raw);
  final candidates = m['candidates'];
  if (candidates is! List || candidates.isEmpty) {
    // 安全策略拦截：promptFeedback.blockReason
    final pf = _asMap(m['promptFeedback']);
    final reason = '${pf['blockReason'] ?? pf['block_reason'] ?? ''}'.trim();
    if (reason.isNotEmpty) {
      throw ImageEditException(
        ImageEditErrorKind.contentBlocked,
        imageEditErrorText(ImageEditErrorKind.contentBlocked, {
          'tail': sanitizeServerText(reason),
        }),
      );
    }
    throw ImageEditException(ImageEditErrorKind.invalidImageResult);
  }
  final images = <Uint8List>[];
  var failed = 0;
  var lastInvalid = ImageEditErrorKind.invalidImageResult;
  for (final c in candidates) {
    final cm = _asMap(c);
    final finish = '${cm['finishReason'] ?? cm['finish_reason'] ?? ''}'.trim();
    final content = _asMap(cm['content']);
    final parts = content['parts'];
    if (parts is! List) continue;
    for (final p in parts) {
      final pm = _asMap(p);
      final inline = _asMap(pm['inlineData'] ?? pm['inline_data']);
      if (inline.isEmpty) continue;
      final data = inline['data'];
      if (data is! String) {
        failed++;
        continue;
      }
      try {
        images.add(decodeImageBase64(data));
      } on ImageEditException catch (ex) {
        lastInvalid = ex.kind;
        failed++;
      }
    }
    // 候选被安全策略掐断，且一张图都没有
    if (images.isEmpty &&
        (finish == 'SAFETY' ||
            finish == 'PROHIBITED_CONTENT' ||
            finish == 'BLOCKLIST' ||
            finish == 'RECITATION')) {
      throw ImageEditException(
        ImageEditErrorKind.contentBlocked,
        imageEditErrorText(ImageEditErrorKind.contentBlocked, {
          'tail': sanitizeServerText(finish),
        }),
      );
    }
  }
  if (images.isEmpty) throw ImageEditException(lastInvalid);
  return ImageEditOutcome(images: images, requested: requested, failed: failed);
}

/// B1 响应：`{"images":["<base64>", …]}`（`info` 里可能含提示词，**一律不采用**）
ImageEditOutcome parseA1111EditResponse(Object? raw, {required int requested}) {
  final errKind = _bodyError(raw);
  if (errKind != null) throw errKind;
  final m = _asMap(raw);
  final list = m['images'];
  if (list is! List || list.isEmpty) {
    throw ImageEditException(ImageEditErrorKind.invalidImageResult);
  }
  final images = <Uint8List>[];
  var failed = 0;
  var lastInvalid = ImageEditErrorKind.invalidImageResult;
  for (final one in list) {
    if (one is! String) {
      failed++;
      continue;
    }
    try {
      images.add(decodeImageBase64(one));
    } on ImageEditException catch (ex) {
      lastInvalid = ex.kind;
      failed++;
    }
  }
  if (images.isEmpty) throw ImageEditException(lastInvalid);
  return ImageEditOutcome(images: images, requested: requested, failed: failed);
}

/// 响应体里带 `error` → 抛"服务端在响应里返回了错误"（200 也可能带）
ImageEditException? _bodyError(Object? raw) {
  final m = _asMap(raw);
  if (m.isEmpty) return null;
  final err = m['error'];
  if (err == null) return null;
  final tail = sanitizeServerText(raw);
  if (tail.isEmpty) return null;
  final lower = tail.toLowerCase();
  if (lower.contains('safety') ||
      lower.contains('blocked') ||
      lower.contains('content policy')) {
    return ImageEditException(
      ImageEditErrorKind.contentBlocked,
      imageEditErrorText(ImageEditErrorKind.contentBlocked, {'tail': tail}),
    );
  }
  return ImageEditException(
    ImageEditErrorKind.serverErrorBody,
    imageEditErrorText(ImageEditErrorKind.serverErrorBody, {'tail': tail}),
  );
}

Map<String, dynamic> _asMap(Object? raw) {
  if (raw is Map) return raw.map((k, v) => MapEntry('$k', v));
  return const {};
}

// ------------------------------------------------------------------- 客户端

/// 三类后端的图生图客户端（Dio 语义复用 `cloud_llm_client.dart`）
class ImageEditClient {
  ImageEditClient({Dio? dio})
    : _dio = tagDioWithModule(
        dio ??
            Dio(
              BaseOptions(
                connectTimeout: kImageEditConnectTimeout,
                // 出图比出字慢：接收超时给到 180s（Q2【待取证】，先用保守值）
                receiveTimeout: kImageEditGenerateTimeout,
                sendTimeout: const Duration(seconds: 60),
                // 4xx/5xx 自己解析 body，不抛成 DioException 的兜底路径
                validateStatus: (_) => true,
              ),
            ),
        TrafficModules.ai,
      );

  final Dio _dio;

  /// 连接超时（【待取证】Q2：真机实测后可能要调）
  static const Duration kImageEditConnectTimeout = Duration(seconds: 20);

  /// 生成超时（【待取证】Q2：局域网 A1111 可能更久）
  static const Duration kImageEditGenerateTimeout = Duration(seconds: 180);

  Future<ImageEditOutcome> edit({
    required ImageEditConfig cfg,
    required Uint8List imageBytes,
    String fileName = 'image.jpg',
    String mimeType = 'image/jpeg',
    CancelToken? cancel,
  }) async {
    if (cfg.effectivePrompt.isEmpty) {
      throw ImageEditException(ImageEditErrorKind.promptEmpty);
    }
    if (cfg.effectivePrompt.length > kImageEditPromptMaxChars) {
      throw ImageEditException(
        ImageEditErrorKind.promptTooLong,
        imageEditErrorText(ImageEditErrorKind.promptTooLong, {
          'chars': '${cfg.effectivePrompt.length}',
          'limit': '$kImageEditPromptMaxChars',
        }),
      );
    }
    if (!cfg.usable) {
      throw ImageEditException(ImageEditErrorKind.backendNotConfigured);
    }
    final plan = buildImageEditPlan(
      cfg,
      imageBytes,
      fileName: fileName,
      mimeType: mimeType,
    );
    Response<dynamic> res;
    try {
      res = await _dio.request<dynamic>(
        plan.url.toString(),
        data: plan.body,
        options: Options(
          method: 'POST',
          headers: plan.headers,
          responseType: ResponseType.plain,
        ),
        cancelToken: cancel,
      );
    } on DioException catch (e) {
      throw _dioError(e, cfg: cfg);
    }
    final code = res.statusCode ?? 0;
    final body = res.data;
    if (code < 200 || code >= 300) {
      final kind = _httpKind(code);
      throw ImageEditException(
        kind,
        imageEditErrorText(kind, {
          if (kind == ImageEditErrorKind.notFound ||
              kind == ImageEditErrorKind.connectTimeout)
            'host': imageEditHostOf(cfg.baseUrl),
          'code': '$code',
          'tail': sanitizeServerText(body, secrets: cfg.secrets),
        }),
      );
    }
    final decoded = _decodeBody(body, cfg: cfg);
    return switch (cfg.backend) {
      ImageEditBackend.openAiImagesEdits => parseOpenAiEditResponse(
        decoded,
        requested: cfg.variantCount,
      ),
      ImageEditBackend.geminiGenerateContent => parseGeminiEditResponse(
        decoded,
        requested: cfg.variantCount,
      ),
      ImageEditBackend.a1111Img2Img => parseA1111EditResponse(
        decoded,
        requested: cfg.variantCount,
      ),
    };
  }

  /// 响应体可能是 String（ResponseType.plain）→ 解成 JSON；不是 JSON 就抛确定错误
  Object? _decodeBody(Object? body, {required ImageEditConfig cfg}) {
    if (body is String) {
      final t = body.trim();
      if (t.isEmpty) {
        throw ImageEditException(ImageEditErrorKind.invalidImageResult);
      }
      try {
        return jsonDecode(t);
      } on FormatException catch (e) {
        throw ImageEditException(
          ImageEditErrorKind.notJson,
          imageEditErrorText(ImageEditErrorKind.notJson, {
            'error': sanitizeServerText('$e', secrets: cfg.secrets),
          }),
        );
      }
    }
    return body;
  }

  ImageEditErrorKind _httpKind(int code) => switch (code) {
    400 => ImageEditErrorKind.requestRejected,
    401 => ImageEditErrorKind.keyInvalid,
    402 => ImageEditErrorKind.insufficientBalance,
    403 => ImageEditErrorKind.noPermission,
    404 => ImageEditErrorKind.notFound,
    413 => ImageEditErrorKind.bodyTooLarge,
    422 => ImageEditErrorKind.paramsRejected,
    429 => ImageEditErrorKind.rateLimited,
    >= 500 => ImageEditErrorKind.serverError,
    _ => ImageEditErrorKind.requestFailed,
  };

  ImageEditException _dioError(DioException e, {required ImageEditConfig cfg}) {
    final host = e.requestOptions.uri.host;
    final isLocal = cloudIsLocalEndpoint('http://$host');
    final kind = switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout => ImageEditErrorKind.connectTimeout,
      DioExceptionType.receiveTimeout => ImageEditErrorKind.generateTimeout,
      DioExceptionType.badCertificate => ImageEditErrorKind.badCertificate,
      DioExceptionType.cancel => ImageEditErrorKind.cancelledBilling,
      DioExceptionType.connectionError =>
        isLocal
            ? ImageEditErrorKind.localUnreachable
            : ImageEditErrorKind.unreachable,
      _ => ImageEditErrorKind.unknownNetwork,
    };
    return ImageEditException(
      kind,
      imageEditErrorText(kind, {
        'host': host,
        'seconds': '${kImageEditGenerateTimeout.inSeconds}',
        'error': sanitizeServerText(
          e.error ?? e.message ?? e.type.name,
          secrets: cfg.secrets,
        ),
      }),
    );
  }
}
