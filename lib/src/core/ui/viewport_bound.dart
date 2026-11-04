/// `MediaQuery.sizeOf(context) * 系数` 这类"经验系数尺寸"的**安全边界**。
///
/// UI 审计 P2-7 ~ P2-9：这类写法没有下界时，极矮 / 极窄视口会把弹层或气泡压到
/// 0（内容不可见）；没有上界时，平板 / 折叠屏展开后又会让弹层反常地占满整屏。
///
/// ⚠️ 这里只加**安全边界**，不改变常见视口下的取值：审计矩阵用到的所有尺寸
/// （宽 360/393/411/800，高 640/852/891/1280）上，结果与加 clamp 之前逐像素相同
/// —— 也就是说这层边界只在极端视口上生效，不引入外观变更。
library;

/// 横向内容的最大宽度（例如聊天气泡、设计预览里的气泡）。
///
/// * 下界 160：窄屏（<205 逻辑像素）下仍要放得下一行短文案，不允许随系数趋近 0；
/// * 上界 900：超过常见阅读宽度的内容没必要更宽，避免超宽视口上"整行铺满"。
double boundedViewportWidth(double viewportWidth, double fraction) =>
    (viewportWidth * fraction).clamp(160.0, 900.0);

/// 纵向弹层的最大高度（bottom sheet / picker）。
///
/// * 下界 180：至少放得下一行标题 + 一行内容（大字号下也不被压成 0）；
/// * 上界 1200：弹层内容本身可滚动，超过这个高度没有意义，避免超高视口上
///   弹层吃掉整屏。
double boundedViewportHeight(double viewportHeight, double fraction) =>
    (viewportHeight * fraction).clamp(180.0, 1200.0);
