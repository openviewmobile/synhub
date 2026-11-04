// 相册 AI 美化（图生图）的**预设提示词模板**与**强度映射**（纯数据 + 纯函数）。
//
// 三条纪律：
//   1. **不承诺效果**：模板只把用户意图翻译成一句中文提示词，文案里不许出现
//      "AI 已优化"这类既成事实（见 `docs/photo-ai-image-to-image-plan.md` §5.2）。
//   2. **改成"能说得清"的写法**：强度（弱/中/强）在 OpenAI 兼容 / Gemini
//      这两个"没有强度参数"的后端上，只能**改写提示词前缀**；在 A1111 上
//      才映射成 `denoising_strength` 0.2 / 0.4 / 0.6（§5.3）。
//   3. **纯 Dart**：不许 import flutter / dart:ui（与 `data_text.dart` 同约束），
//      文案一律 "key + 中文原文"，翻译由 Flutter 层注入。
library;

import '../../core/i18n/data_text.dart';

/// 强度档位。UI 只暴露这一个统一旋钮，后端差异由适配层吸收。
enum ImageEditStrength {
  weak('weak', '弱', 0.2, 'imageEditStrengthWeak'),
  medium('medium', '中', 0.4, 'imageEditStrengthMedium'),
  strong('strong', '强', 0.6, 'imageEditStrengthStrong');

  const ImageEditStrength(this.id, this.label, this.denoising, this.labelKey);

  final String id;

  /// 中文标签（**回落**；界面走 [labelText]）
  final String label;

  /// A1111 的 `denoising_strength`（弱/中/强 = 0.2/0.4/0.6）
  final double denoising;

  /// 数据层文案 key
  final String labelKey;

  String get labelText => dataText(labelKey, label);

  /// 默认强度：中
  static const ImageEditStrength fallback = ImageEditStrength.medium;

  static ImageEditStrength fromId(String? id) => switch (id) {
    'weak' => ImageEditStrength.weak,
    'strong' => ImageEditStrength.strong,
    _ => ImageEditStrength.medium,
  };
}

/// 一次图生图的提示词最大字符数。
///
/// 取值口径：**最保守的那个官方下限** —— OpenAI `dall-e-2` 的 `prompt`
/// 上限是 1000 字符（GPT image 模型允许 32000）；取小的那个当通用上限，
/// 免得配置成 dall-e-2 时被服务端 400。来源见方案 §4.1 A1 的字段表
/// （openai-python `image_edit_params.py`）。
const int kImageEditPromptMaxChars = 1000;

/// 把强度改写成提示词前缀（A1 / A2 用；B1 用 [ImageEditStrength.denoising]）。
///
/// 空提示词原样返回空串（"自定义"模板的必填校验在别处做，不在这里编造内容）。
String applyStrengthToPrompt(ImageEditStrength strength, String prompt) {
  final p = prompt.trim();
  if (p.isEmpty) return p;
  return switch (strength) {
    // 前缀措辞是产品选择，不涉及后端能力差异
    ImageEditStrength.weak => '尽量轻微地修改，保留原始构图与人物特征：$p',
    ImageEditStrength.medium => p,
    ImageEditStrength.strong => '大幅度重绘风格，但保留主体姿态与人物特征：$p',
  };
}

/// 一个预设模板（纯数据）
class ImageEditPromptTemplate {
  const ImageEditPromptTemplate({
    required this.id,
    required this.labelKey,
    required this.labelZh,
    required this.promptKey,
    required this.promptZh,
    required this.strength,
    this.editable = true,
    this.noticeKey = '',
    this.noticeZh = '',
  });

  /// 稳定 id（落偏好/统计用；**不是**展示文案）
  final String id;

  final String labelKey;
  final String labelZh;

  /// 提示词模板的文案 key（同一 key 已被 `dataText` 接管）
  final String promptKey;
  final String promptZh;

  /// 该模板的默认强度
  final ImageEditStrength strength;

  /// 填进输入框后还能不能编辑（现在全部可编辑；"自定义"只是初始为空）
  final bool editable;

  /// 额外标注（只有"证件照换底"用：**不保证符合规格**）
  final String noticeKey;
  final String noticeZh;

  String get labelText => dataText(labelKey, labelZh);

  String get promptText => dataText(promptKey, promptZh);

  String get noticeText =>
      noticeKey.isEmpty ? '' : dataText(noticeKey, noticeZh);
}

/// 7 个预设模板（顺序即界面顺序）。
///
/// ⚠️ 模板里**不含**任何"换脸 / 让某人做某事 / 改身份"的用途（§6.6）。
const List<ImageEditPromptTemplate> kImageEditPromptTemplates = [
  ImageEditPromptTemplate(
    id: 'enhance',
    labelKey: 'imageEditPresetEnhance',
    labelZh: '提升清晰度',
    promptKey: 'imageEditPresetEnhancePrompt',
    promptZh: '提升清晰度与细节，去除模糊，保留原始构图与人物特征',
    strength: ImageEditStrength.weak,
  ),
  ImageEditPromptTemplate(
    id: 'denoise',
    labelKey: 'imageEditPresetDenoise',
    labelZh: '去噪/降噪',
    promptKey: 'imageEditPresetDenoisePrompt',
    promptZh: '去除噪点与压缩痕迹，保留纹理与文字细节',
    strength: ImageEditStrength.medium,
  ),
  ImageEditPromptTemplate(
    id: 'realistic',
    labelKey: 'imageEditPresetRealistic',
    labelZh: '风格化（写实）',
    promptKey: 'imageEditPresetRealisticPrompt',
    promptZh: '转为通透的写实摄影风格，自然光，保留原场景',
    strength: ImageEditStrength.strong,
  ),
  ImageEditPromptTemplate(
    id: 'illustration',
    labelKey: 'imageEditPresetIllustration',
    labelZh: '风格化（插画）',
    promptKey: 'imageEditPresetIllustrationPrompt',
    promptZh: '转为柔和手绘插画风格，保留主体姿态与配色',
    strength: ImageEditStrength.strong,
  ),
  ImageEditPromptTemplate(
    id: 'idPhoto',
    labelKey: 'imageEditPresetIdPhoto',
    labelZh: '证件照换底',
    promptKey: 'imageEditPresetIdPhotoPrompt',
    promptZh: '保持人物面部与发型不变，将背景替换为纯色背景',
    strength: ImageEditStrength.medium,
    // 必须提示：这不是合规的证件照工具
    noticeKey: 'imageEditPresetIdPhotoNotice',
    noticeZh: '结果不保证符合证件照规格，请勿直接用于正式办理',
  ),
  ImageEditPromptTemplate(
    id: 'restore',
    labelKey: 'imageEditPresetRestore',
    labelZh: '老照片修复',
    promptKey: 'imageEditPresetRestorePrompt',
    promptZh: '修复划痕与褪色，适度锐化，不改变人物长相',
    strength: ImageEditStrength.medium,
  ),
  ImageEditPromptTemplate(
    id: 'custom',
    labelKey: 'imageEditPresetCustom',
    labelZh: '自定义',
    promptKey: 'imageEditPresetCustomPrompt',
    // 自定义模板**初始为空**，不预填任何内容（必填校验交给调用方）
    promptZh: '',
    strength: ImageEditStrength.medium,
  ),
];

/// 按 id 取模板（认不出返回 null；调用方决定怎么提示）
ImageEditPromptTemplate? imageEditTemplateById(String id) {
  for (final t in kImageEditPromptTemplates) {
    if (t.id == id) return t;
  }
  return null;
}
