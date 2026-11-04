// 模块内"能力位降级"的一句话提示（S2 任务 2 复用件）。
//
// 场景：服务的**必需** API 都在（模块本身可用），只是某个**可选**能力位
// （注册表 `optionalApis`）在你的 NAS 上缺失 → 不隐藏模块，只在对应功能
// 旁边给一句原因。
//
// 文案：通用场景用 `capabilityMissingHint`（"此功能在你的 NAS 上不可用"）；
// 具体功能有更贴切的 key 时，通过 [CapabilityDegradeHint.detail] 传进来
// （例如音频缺 `AudioStation.Stream` 传 `asStreamUnavailable`）。
import 'package:flutter/material.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';

/// 一行降级提示：图标 + 一句话原因。
///
/// 用法（模块内）：
/// ```dart
/// final t = context.t;
/// final canTodo = ref.watch(serviceAvailabilityProvider)
///     .hasApi(StationService.note, kNoteTodoApi);
/// if (!canTodo) return const CapabilityDegradeHint();
/// ```
class CapabilityDegradeHint extends StatelessWidget {
  const CapabilityDegradeHint({
    super.key,
    this.detail,
    this.icon = Icons.info_outline,
    this.dense = true,
  });

  /// 一句话原因；为空时回落到通用的"此功能在你的 NAS 上不可用"。
  final String? detail;
  final IconData icon;

  /// 紧凑模式（放在工具栏 / 表单旁）；false 时给更大的留白（整页空态）。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final meta = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim);
    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: DesignPalette.of(context).dim),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(detail ?? context.t.capabilityMissingHint, style: meta),
        ),
      ],
    );
    if (!dense) {
      return Padding(padding: const EdgeInsets.all(Gap.lg), child: content);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
      child: content,
    );
  }
}
