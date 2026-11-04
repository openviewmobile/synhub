// 「AI 美化（图生图）」**独立设置页**（第 255 轮）。
//
// ## 为什么独立成页（用户 2026-09-25 原话）
// 「目前图生图设置怎么和大语言模型设置混在一起了？能否拆开独立配置？」
//
// 之前 `PhotoAiEditSettingsCard` 被挂在大语言模型页
// （`features/ai/ai_model_page.dart`）里 —— 于是同一页上并排放着
// "档位 / 端侧模型目录 / 本机算力门槛"和"图生图后端 / API Key / 单日上限"，
// 两件**互不相干**的事（一个是"聊天用哪个模型"，一个是"照片重绘发给谁"）。
//
// 现在：
//   * 本页 = 图生图**唯一**配置入口（设置 → 隐私 → AI 美化（图生图））；
//   * 大语言模型页**不再**出现图生图的任何控件（见该页注释）；
//   * 两边的配置项、开关、存储键本来就各自独立（`imageEdit*` 偏好键 +
//     `kImageEditKeySlot` 安全槽 vs `cloudLlm*` / 端侧模型目录），
//     本页只是把"入口"也拆开，**没有**改任何存储或协议。
//
// 纪律：本页不做任何联网探测；同意只能在结果提交前的阻断式页面里显式点击
// （`photo_ai_edit_sheet.dart`），这里只有"撤销同意"。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/theme/app_tokens.dart';
import 'photo_ai_edit_settings.dart';
import 'photo_ai_edit_text.dart';

/// 图生图（照片 AI 美化）设置页。
class PhotoAiEditSettingsPage extends ConsumerWidget {
  const PhotoAiEditSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return DesignScaffold(
      appBar: AppBar(
        title: Text(
          photoAiEdit(PhotoAiEditTextKeys.settingsEntry, 'AI 美化（图生图）'),
        ),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 0),
            child: Text(
              photoAiEdit(
                PhotoAiEditTextKeys.settingsPageIntro,
                '这里只配置「照片 AI 美化（图生图）」这一条通道：'
                    '选中的照片会发往你填写的服务地址做重绘，不经过本应用的服务器。',
              ),
              style: theme.textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, 0),
            child: Text(
              photoAiEdit(
                PhotoAiEditTextKeys.settingsSeparateNote,
                '与「AI 服务」里的大语言模型档位（云端 / 端侧 / 内置摘要）'
                    '各自独立，互不影响：改这里的后端与额度，不会动聊天用的模型。',
              ),
              style: theme.textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
            ),
          ),
          const PhotoAiEditSettingsCard(),
          const SizedBox(height: Gap.lg),
        ],
      ),
    );
  }
}
