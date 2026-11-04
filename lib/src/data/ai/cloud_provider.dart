// 云端大模型的**厂商清单与协议定义**。
//
// 为什么以"OpenAI 兼容"为默认协议（业界惯例）：
//   * 现在绝大多数厂商（国内外的商业 API、以及自建的 Ollama / LM Studio / vLLM /
//     one-api 网关）都提供 `POST {base}/chat/completions` + `Authorization: Bearer` +
//     `GET {base}/models` 这套形状；
//   * 所以"一个 OpenAI 兼容客户端 + 可改 base URL"就能覆盖绝大部分场景，
//     用户想接没列出来的厂商时，选「自定义」填 URL 即可（这是 Cherry Studio /
//     Open WebUI / LobeChat 这类工具的通行做法）。
//   * Anthropic 与 Gemini 的协议形状不同（鉴权头、请求体、SSE 事件名都不同），
//     单独实现，但同样走一个 `CloudLlmClient`，UI 上不用分叉。
//
// ⚠️ base URL 的约定：**要带版本路径**（例如 `https://api.openai.com/v1`），
// 客户端只负责拼 `/chat/completions`、`/messages`、`/models`。
// 用户如果粘了带 `/chat/completions` 尾巴的整条地址，[normalizeBaseUrl] 会去掉。
//
// 文案（批次 2d）：本文件**纯 Dart**（不许 import flutter/l10n），
// 所有中文都是"key + 中文原文"经 [dataText] 取译文，译文由 Flutter 层注入。
// 界面一律读 `xxxText`（`nameText` / `noteText` / `keyHintText` / `labelText`），
// 中文原字段只当**无翻译器时的回落**。
import '../../core/i18n/data_text.dart';

/// 云端协议（决定请求形状、鉴权头、SSE 解析方式）
enum CloudProtocol {
  openai('openai', 'OpenAI 兼容', 'aiProtoOpenai'),
  anthropic('anthropic', 'Anthropic Messages', ''),
  gemini('gemini', 'Google Gemini', '');

  const CloudProtocol(this.id, this.label, this.labelKey);

  final String id;

  /// 中文标签（**回落**；界面走 [labelText]）
  final String label;

  /// 数据层文案 key；空串 = 这段文案本来就无需翻译
  final String labelKey;

  /// 本地化标签（没装翻译器时就是 [label]）
  String get labelText => labelKey.isEmpty ? label : dataText(labelKey, label);

  static CloudProtocol fromId(String? id) => switch (id) {
    'anthropic' => CloudProtocol.anthropic,
    'gemini' => CloudProtocol.gemini,
    _ => CloudProtocol.openai,
  };
}

/// 一个可选的云端厂商
class CloudProviderInfo {
  const CloudProviderInfo({
    required this.id,
    required this.name,
    required this.protocol,
    required this.baseUrl,
    this.nameKey = '',
    this.keyHint = '',
    this.keyHintKey = '',
    this.docsUrl = '',
    this.note = '',
    this.noteKey = '',
    this.needsKey = true,
    this.supportsModelList = true,
    this.presetModels = const [],
    this.builtin = false,
  });

  final String id;

  /// 中文名（**回落**；界面走 [nameText]）
  final String name;

  /// 数据层文案 key（空串 = 无需翻译，例如 "OpenAI"）
  final String nameKey;

  final CloudProtocol protocol;

  /// 默认 base URL（带版本路径）；自定义厂商为空串
  final String baseUrl;

  /// 输入框里的占位提示（各家 key 长相不同，提示一下能少踩坑）
  final String keyHint;
  final String keyHintKey;

  /// 官方文档（"去哪里拿 key"）
  final String docsUrl;

  /// 界面上的一句提醒（额度、区域、兼容性坑）
  final String note;
  final String noteKey;

  /// 是否必须填 key（本地 Ollama/LM Studio 通常不需要）
  final bool needsKey;

  /// 这家有没有 `GET /models` 接口。
  ///
  /// ⚠️ 实测（官方文档逐条核对）确认：**智谱 GLM 与阿里云百炼的
  /// OpenAI 兼容层没有模型列表接口**，所以这两家必须让用户手填 model id ——
  /// 这不是"可选兜底"，是刚需。
  final bool supportsModelList;

  /// 常见的模型 id（拉不到列表时给用户点选，避免手打错）
  final List<String> presetModels;

  /// 是否是我们内置的预设（false = 用户自定义）
  final bool builtin;

  bool get isCustom => id == kCustomProviderId;

  /// 厂商名的当前语言版本
  String get nameText => nameKey.isEmpty ? name : dataText(nameKey, name);

  /// 备注的当前语言版本
  String get noteText => noteKey.isEmpty ? note : dataText(noteKey, note);

  /// key 占位提示的当前语言版本
  String get keyHintText =>
      keyHintKey.isEmpty ? keyHint : dataText(keyHintKey, keyHint);
}

const String kCustomProviderId = 'custom';

/// 内置厂商预设
///
/// 排序：先国外主流，再国内主流，最后"自建/本地"——用户最可能用的是前两类。
const List<CloudProviderInfo> kCloudProviders = [
  CloudProviderInfo(
    id: 'openai',
    name: 'OpenAI',
    protocol: CloudProtocol.openai,
    baseUrl: 'https://api.openai.com/v1',
    keyHint: 'sk-...',
    docsUrl: 'https://platform.openai.com/api-keys',
    note: '国内直连通常不通，需要代理或中转地址',
    noteKey: 'aiProvOpenaiNote',
    presetModels: ['gpt-4o-mini', 'gpt-4o', 'gpt-4.1-mini', 'o4-mini'],
    builtin: true,
  ),
  CloudProviderInfo(
    id: 'anthropic',
    name: 'Anthropic Claude',
    protocol: CloudProtocol.anthropic,
    baseUrl: 'https://api.anthropic.com/v1',
    keyHint: 'sk-ant-...',
    docsUrl: 'https://console.anthropic.com/settings/keys',
    note: 'Messages 协议：鉴权用 x-api-key，必须带 anthropic-version 头',
    noteKey: 'aiProvAnthropicNote',
    presetModels: [
      'claude-sonnet-4-5',
      'claude-haiku-4-5',
      'claude-3-7-sonnet-latest',
    ],
    builtin: true,
  ),
  CloudProviderInfo(
    id: 'gemini',
    name: 'Google Gemini',
    protocol: CloudProtocol.gemini,
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    keyHint: 'AIza...',
    docsUrl: 'https://aistudio.google.com/app/apikey',
    note: 'key 走查询串；国内直连通常需要代理',
    noteKey: 'aiProvGeminiNote',
    presetModels: ['gemini-2.0-flash', 'gemini-2.5-flash', 'gemini-2.5-pro'],
    builtin: true,
  ),
  CloudProviderInfo(
    id: 'deepseek',
    name: 'DeepSeek 深度求索',
    nameKey: 'aiProvDeepseekName',
    protocol: CloudProtocol.openai,
    baseUrl: 'https://api.deepseek.com/v1',
    keyHint: 'sk-...',
    docsUrl: 'https://platform.deepseek.com/api_keys',
    note: '中文/代码能力强、价格低（官方示例用 api.deepseek.com，/v1 也兼容）',
    noteKey: 'aiProvDeepseekNote',
    presetModels: ['deepseek-chat', 'deepseek-reasoner'],
    builtin: true,
  ),
  CloudProviderInfo(
    id: 'moonshot',
    name: 'Moonshot Kimi',
    protocol: CloudProtocol.openai,
    baseUrl: 'https://api.moonshot.cn/v1',
    keyHint: 'sk-...',
    docsUrl: 'https://platform.moonshot.cn/console/api-keys',
    note: '长文本见长',
    noteKey: 'aiProvMoonshotNote',
    presetModels: [
      'moonshot-v1-8k',
      'moonshot-v1-32k',
      'moonshot-v1-128k',
      'kimi-k2-0711-preview',
    ],
    builtin: true,
  ),
  CloudProviderInfo(
    id: 'zhipu',
    name: '智谱 GLM',
    nameKey: 'aiProvZhipuName',
    protocol: CloudProtocol.openai,
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    keyHint: '形如 id.secret',
    keyHintKey: 'aiProvZhipuKeyHint',
    docsUrl: 'https://open.bigmodel.cn/usercenter/apikeys',
    note: 'base URL 带 /api/paas/v4；没有模型列表接口，模型 id 手填',
    noteKey: 'aiProvZhipuNote',
    supportsModelList: false,
    presetModels: ['glm-4-flash', 'glm-4-air', 'glm-4-plus'],
    builtin: true,
  ),
  CloudProviderInfo(
    id: 'dashscope',
    name: '阿里云百炼（通义千问）',
    nameKey: 'aiProvDashscopeName',
    protocol: CloudProtocol.openai,
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    keyHint: 'sk-...',
    docsUrl: 'https://bailian.console.aliyun.com/',
    note:
        '必须用 compatible-mode 这段路径；官方未记载列表接口，模型 id 手填；'
        '新域名带 WorkspaceId 且 key 按地域绑定（北京 key 调新加坡会 401）',
    noteKey: 'aiProvDashscopeNote',
    supportsModelList: false,
    presetModels: ['qwen-plus', 'qwen-turbo', 'qwen-max', 'qwen-long'],
    builtin: true,
  ),
  CloudProviderInfo(
    id: 'siliconflow',
    name: '硅基流动 SiliconFlow',
    nameKey: 'aiProvSiliconflowName',
    protocol: CloudProtocol.openai,
    baseUrl: 'https://api.siliconflow.cn/v1',
    keyHint: 'sk-...',
    docsUrl: 'https://cloud.siliconflow.cn/account/ak',
    note: '一个 key 能调很多开源模型',
    noteKey: 'aiProvSiliconflowNote',
    presetModels: [
      'Qwen/Qwen3-8B',
      'deepseek-ai/DeepSeek-V3',
      'THUDM/glm-4-9b-chat',
    ],
    builtin: true,
  ),
  CloudProviderInfo(
    id: 'volces',
    name: '火山方舟（豆包）',
    nameKey: 'aiProvVolcesName',
    protocol: CloudProtocol.openai,
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    keyHint: '形如 uuid',
    keyHintKey: 'aiProvVolcesKeyHint',
    docsUrl: 'https://console.volcengine.com/ark',
    note:
        '模型 id 要填"推理接入点"（ep-…）；'
        '官方文档站是 JS 渲染，base URL 没能逐字核实，连不上就换中转地址',
    noteKey: 'aiProvVolcesNote',
    presetModels: ['doubao-seed-1-6-250615'],
    builtin: true,
  ),
  CloudProviderInfo(
    id: 'openrouter',
    name: 'OpenRouter',
    protocol: CloudProtocol.openai,
    baseUrl: 'https://openrouter.ai/api/v1',
    keyHint: 'sk-or-...',
    docsUrl: 'https://openrouter.ai/keys',
    note: '一个 key 转发几百个模型',
    noteKey: 'aiProvOpenrouterNote',
    presetModels: [
      'openai/gpt-4o-mini',
      'anthropic/claude-3.5-sonnet',
      'google/gemini-2.0-flash-001',
      'deepseek/deepseek-chat',
    ],
    builtin: true,
  ),
  CloudProviderInfo(
    id: 'qianfan',
    name: '百度千帆',
    nameKey: 'aiProvQianfanName',
    protocol: CloudProtocol.openai,
    baseUrl: 'https://qianfan.baidubce.com/v2',
    keyHint: 'bce-v3/ALTAK-...',
    docsUrl: 'https://console.bce.baidu.com/iam/#/iam/apikey/list',
    note: 'base URL 带 /v2；key 是 bce-v3 那种长串',
    noteKey: 'aiProvQianfanNote',
    presetModels: ['ernie-4.5-turbo-128k', 'ernie-speed-128k'],
    builtin: true,
  ),
  CloudProviderInfo(
    id: 'hunyuan',
    name: '腾讯混元',
    nameKey: 'aiProvHunyuanName',
    protocol: CloudProtocol.openai,
    baseUrl: 'https://api.hunyuan.cloud.tencent.com/v1',
    keyHint: 'sk-...',
    docsUrl: 'https://console.cloud.tencent.com/hunyuan/api-key',
    note: '官方未给模型列表接口，模型 id 手填；后续会迁到 TokenHub',
    noteKey: 'aiProvHunyuanNote',
    supportsModelList: false,
    presetModels: ['hunyuan-turbos-latest', 'hunyuan-lite'],
    builtin: true,
  ),
  CloudProviderInfo(
    id: 'ollama',
    name: 'Ollama（本机/局域网）',
    nameKey: 'aiProvOllamaName',
    protocol: CloudProtocol.openai,
    baseUrl: 'http://localhost:11434/v1',
    keyHint: 'Ollama 不校验，留空也行',
    keyHintKey: 'aiProvOllamaKeyHint',
    needsKey: false,
    note:
        '默认端口 11434；手机连电脑要把 localhost 换成电脑的局域网 IP。'
        'OpenAI 兼容层要求带 key 字段但会忽略它，我们会自动补一个占位值',
    noteKey: 'aiProvOllamaNote',
    presetModels: ['qwen3:8b', 'llama3.2', 'gemma3:4b'],
    builtin: true,
  ),
  CloudProviderInfo(
    id: 'lmstudio',
    name: 'LM Studio（本机/局域网）',
    nameKey: 'aiProvLmstudioName',
    protocol: CloudProtocol.openai,
    baseUrl: 'http://localhost:1234/v1',
    keyHint: '不校验，随便填或留空',
    keyHintKey: 'aiProvLmstudioKeyHint',
    needsKey: false,
    note: '默认端口 1234',
    noteKey: 'aiProvLmstudioNote',
    builtin: true,
  ),
  CloudProviderInfo(
    id: 'vllm',
    name: 'vLLM / 自建 OpenAI 服务',
    nameKey: 'aiProvVllmName',
    protocol: CloudProtocol.openai,
    baseUrl: 'http://localhost:8000/v1',
    keyHint: '看服务端配置',
    keyHintKey: 'aiProvVllmKeyHint',
    needsKey: false,
    note: '默认端口 8000；one-api / new-api / LiteLLM 这类网关也走这条',
    noteKey: 'aiProvVllmNote',
    builtin: true,
  ),
  CloudProviderInfo(
    id: kCustomProviderId,
    name: '自定义 / 中转地址',
    nameKey: 'aiProvCustomName',
    protocol: CloudProtocol.openai,
    baseUrl: '',
    keyHint: '按服务商要求填写',
    keyHintKey: 'aiProvCustomKeyHint',
    note: '填完整的 base URL（带版本路径），可选协议类型',
    noteKey: 'aiProvCustomNote',
    builtin: true,
  ),
];

CloudProviderInfo? cloudProviderById(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final p in kCloudProviders) {
    if (p.id == id) return p;
  }
  return null;
}

/// 把用户粘进来的 base URL 收拾成"可以拼 /chat/completions"的样子。
///
/// 处理三种最常见的输入错误：
///   * 结尾多余斜杠：`…/v1/` → `…/v1`
///   * 直接粘了整条对话地址：`…/v1/chat/completions` → `…/v1`
///     （也顺手处理 `/messages`、`/completions`）
///   * 粘了带空格的串
String normalizeBaseUrl(String raw) {
  var s = raw.trim();
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  for (final tail in const [
    '/chat/completions',
    '/completions',
    '/messages',
    '/models',
  ]) {
    if (s.toLowerCase().endsWith(tail)) {
      s = s.substring(0, s.length - tail.length);
      break;
    }
  }
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// 拉不到模型列表时的兜底建议
String modelPickerHint(CloudProviderInfo p) => p.presetModels.isEmpty
    ? dataText('aiModelPickerManual', '直接手填模型 id')
    : dataText('aiModelPickerCommon', '也可以从下面这些常见模型里挑');

/// 把 key 打码显示（只留头尾，中间用点）
String maskKey(String key) {
  if (key.isEmpty) return '';
  if (key.length <= 8) return '${key[0]}••••';
  return '${key.substring(0, 3)}••••${key.substring(key.length - 4)}';
}
