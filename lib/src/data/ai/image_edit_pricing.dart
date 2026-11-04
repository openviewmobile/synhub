// 相册 AI 美化（图生图）的**按张计价 + 单日额度 + 并发闸门**（纯 Dart，数据层）。
//
// 三条立场（与 `cloud_pricing.dart` 同一纪律）：
//   1. **单价未知就不猜。** [kImagePrices] 目前是**空表** —— 各家图像模型的
//      "按张单价"在本环境拉不到官方定价页（方案 §11 Q1，`platform.openai.com/pricing`
//      被 Cloudflare 拦截），**禁止凭记忆写数字**。空表 → 认不出单价 →
//      `priced:false`，界面显示"单价未知"且**不计入合计**。
//      拿到官方原文后，只需往 [kImagePrices] 加一行 + 更新 [kImagePricingUpdatedAt]。
//   2. **自建/局域网按 0 计**（复用 `cloudIsLocalEndpoint`，与 token 口径一致）。
//   3. **额度按张数拦，不依赖价格可知**：单价未知时照样拦（这正是硬闸门的意义）。
//
// ⚠️ 与 token 记账的差别：token 是"只估算不拦"，图生图**必须发起前拦**，
// 因为按张计费 + 一次可出多张，沿用旧做法会真花钱且用户无感（方案 §1.3）。
//
// 与 `data_text.dart` 同一约束：**纯 Dart，不许 import flutter**。
library;

import 'cloud_pricing.dart';
import 'image_edit_client.dart';

/// 图生图用量记录的 `kind`（只有种类，**没有内容**；与 summary/askBook/translate 同构）
const String kImageEditUsageKind = 'photoAiEdit';

/// 单日额度默认值：**3 张/日**（0 = 关闭功能；1..10 可调）
const int kImageEditDefaultDailyCap = 3;

/// 单日额度的候选档位（0 = 关闭，界面用）
const List<int> kImageEditDailyCapOptions = [0, 1, 2, 3, 5, 10];

// ------------------------------------------------------------------- 单价

/// 图像模型单价表更新日期。
///
/// **空串 = 从未取证**（当前状态）。取证后写成 `YYYY-MM`，与
/// `kCloudPricingUpdatedAt` 同法。
const String kImagePricingUpdatedAt = '';

/// 一个图像模型的**按张**公开列表价（USD / 张）
class CloudImagePrice {
  const CloudImagePrice({required this.match, required this.perImageUsd});

  /// 匹配片段（小写包含匹配；最长匹配优先，与 token 表同规则）
  final String match;
  final double perImageUsd;
}

/// 图像按张单价表。
///
/// **故意为空**：官方定价页在本环境不可达（Q1）。空表 = 一律 `priced:false`，
/// 绝不拿猜的数字冒充费用。**不许**为了"看起来完整"往这里填记忆里的数字。
const List<CloudImagePrice> kImagePrices = <CloudImagePrice>[];

/// 按模型 id 查图像单价（最长片段优先；表为空时恒为 null）
CloudImagePrice? imagePriceFor(String model) {
  final m = model.trim().toLowerCase();
  if (m.isEmpty) return null;
  CloudImagePrice? best;
  for (final p in kImagePrices) {
    if (!m.contains(p.match)) continue;
    if (best == null || p.match.length > best.match.length) best = p;
  }
  return best;
}

/// 估算一次图生图的费用（**按张**）。
///
/// * 自建/局域网 → `priced:true, usd:0`；
/// * 认不出单价 → `priced:false`（界面显示"单价未知"，不计入合计）；
/// * 认得出 → 张数 × 单价。
CloudCostQuote estimateImageCost({
  required String model,
  required int images,
  String baseUrl = '',
}) {
  final n = images < 0 ? 0 : images;
  if (cloudIsLocalEndpoint(baseUrl)) {
    return const CloudCostQuote(usd: 0, priced: true);
  }
  final price = imagePriceFor(model);
  if (price == null) return CloudCostQuote.unknown;
  return CloudCostQuote(usd: n * price.perImageUsd, priced: true);
}

// ------------------------------------------------------------------- 额度

/// 当日已用的**图片张数**（本地时区；只统计 `kind == photoAiEdit` 的记录）。
///
/// 计数来源是记录里的 `imageCount`：一次请求出 n 张就记 n，
/// 所以"变体数计入上限"天然成立（方案 §7.2）。
int imageEditImagesUsedOnDay(
  List<CloudUsageRecord> records, {
  required int nowMs,
}) {
  final day = cloudUsageDayKey(nowMs);
  var used = 0;
  for (final raw in records) {
    final rec = raw.sanitized();
    if (rec.kind != kImageEditUsageKind) continue;
    if (cloudUsageDayKey(rec.atMs) != day) continue;
    used += rec.imageCount;
  }
  return used;
}

/// 额度快照
class ImageEditQuota {
  const ImageEditQuota({
    required this.used,
    required this.cap,
    required this.remaining,
  });

  final int used;

  /// 0 = 功能关闭
  final int cap;
  final int remaining;

  bool get disabled => cap <= 0;

  bool get exceeded => cap > 0 && remaining <= 0;

  /// 这一次请求（出 [requested] 张）会不会超限
  bool blocks(int requested) {
    if (disabled) return true;
    return requested > remaining;
  }
}

/// 算当天的额度（[nowMs] 只用于取本地日期键，方便跨日测试用可控时钟）
ImageEditQuota imageEditQuota({
  required List<CloudUsageRecord> records,
  required int nowMs,
  required int cap,
}) {
  final used = imageEditImagesUsedOnDay(records, nowMs: nowMs);
  final c = cap < 0 ? 0 : cap;
  final remaining = c <= 0 ? 0 : (c - used).clamp(0, c);
  return ImageEditQuota(used: used, cap: c, remaining: remaining);
}

/// 发起前的额度判定：返回要拦的错误类型（null = 放行）。
///
/// `cap == 0` → 功能关闭（[ImageEditErrorKind.disabled]）；否则张数不够就拦。
ImageEditErrorKind? imageEditQuotaBlock({
  required List<CloudUsageRecord> records,
  required int nowMs,
  required int cap,
  int requested = 1,
}) {
  final q = imageEditQuota(records: records, nowMs: nowMs, cap: cap);
  if (q.disabled) return ImageEditErrorKind.disabled;
  if (q.blocks(requested < 1 ? 1 : requested)) {
    return ImageEditErrorKind.quotaExceeded;
  }
  return null;
}

/// 额度拦截的文案（已填 `{used}`/`{cap}`）
String imageEditQuotaBlockText(ImageEditQuota q) => imageEditErrorText(
  ImageEditErrorKind.quotaExceeded,
  {'used': '${q.used}', 'cap': '${q.cap}'},
);

// --------------------------------------------------------- 并发闸门（上限 1）

/// 全局互斥：**同一时刻只允许一次图生图**（方案 §7.3）。
///
/// 为什么是 1：按张计费 + GPU/云端配额有限 + 多张并行难以向用户解释费用，
/// 所以 N 张必须**串行**。UI 侧禁用入口由 `imageEditBusyProvider` 读这里。
class ImageEditGate {
  bool _inFlight = false;

  bool get inFlight => _inFlight;

  /// 抢锁；已经在跑就返回 false（不排队，由调用方给"正在美化中"）
  bool tryAcquire() {
    if (_inFlight) return false;
    _inFlight = true;
    return true;
  }

  void release() => _inFlight = false;

  /// 包一层：抢不到锁就抛 [ImageEditErrorKind.busy]，无论成败都释放
  Future<T> run<T>(Future<T> Function() body) async {
    if (!tryAcquire()) {
      throw ImageEditException(ImageEditErrorKind.busy);
    }
    try {
      return await body();
    } finally {
      release();
    }
  }
}
