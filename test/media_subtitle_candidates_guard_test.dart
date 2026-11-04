// r438：**字幕源候选清单**的结构守卫（不是功能用例）。
//
// 出处：`docs/android-remaining-todo-r418.md` §二点九-3 ＋ r425 只读复探
// （`docs/evidence-r425/README.md` 的 `r425_subtitle_sources_probe.txt`）：
// `www.podnapisi.net` 直连 **DNS 解析失败**、走 PAC 代理 **TLS 握手失败** ⇒ **域名已死**。
// 这条结论以前只躺在台账/待办里，而 `media_subtitle_search.dart` 头部把它与
// "实测可用"的源并列 ⇒ 下一轮很容易又把它当"可加源"。
//
// 判据认**声明**（仪器122 同族）：要的是"清单里出现 Podnapisi ＋ 明说域名已死 ＋
// 明说不再作为候选 ＋ 带轮次"，不是"文件里出现过某个词"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('r438：Podnapisi 域名已死 ⇒ 头部注释里必须**明确划掉**，不许再当候选源', () {
    final src = File(
      'lib/src/features/media/media_subtitle_search.dart',
    ).readAsStringSync();
    final start = src.indexOf('被否掉的源');
    expect(start, greaterThan(0), reason: '头部必须保留「被否掉的源」清单');
    final block = src.substring(start, (start + 1400).clamp(0, src.length));
    expect(
      block,
      contains('Podnapisi'),
      reason: 'Podnapisi 仍要**在清单里**（是划掉，不是删掉 —— 删掉就没人知道试过了）',
    );
    expect(
      block,
      contains('域名已死'),
      reason: 'r425 的结论（DNS ＋ 代理 TLS 双失败）必须写进源码注释',
    );
    expect(block, contains('r425'), reason: '结论要带轮次，便于回溯');
    expect(
      block,
      contains('不再作为候选'),
      reason: '必须**明说**不再当候选，别留「看起来还支持」的假象',
    );
  });

  // r456：**新找到的免密钥中文源**必须"注释里写清楚 ＋ 代码里真接线"，
  // 而且要守住那条**最容易踩回去**的实测规则（路径必须全小写）。
  //
  // 为什么这条值得守卫：这个口的失败形态是**坏 302**
  // （`location: https://_/search/<小写路径>`，主机字面是 `_`）——
  // 一旦有人"顺手"把查询词按原样（带大写）拼进路径，行为不是"报错"而是
  // `Could not resolve host: _`，看起来像网络问题，排查成本极高。
  test('r456：免密钥老 REST 口 —— 注释写明边界 ＋ 代码真接线 ＋ 全小写规则不许丢', () {
    final src = File(
      'lib/src/features/media/media_subtitle_search.dart',
    ).readAsStringSync();

    // ① 注释：这一节必须在，且写明"免密钥 / 中文 / 全小写 / 坏 302 / 不支持哈希 / 轮次"
    final start = src.indexOf('【4】r456');
    expect(start, greaterThan(0), reason: '头部必须有 r456 的【4】小节');
    final block = src.substring(start, (start + 1600).clamp(0, src.length));
    expect(block, contains('rest.opensubtitles.org'), reason: '要写出确切域名');
    expect(block, contains('免密钥'), reason: '它存在的理由就是免密钥');
    expect(block, contains('chi'), reason: '中文语言码要写出来（这是本轮的动因）');
    expect(block, contains('全小写'), reason: '★ 路径全小写这条最容易被改回去');
    expect(block, contains('302'), reason: '失败形态（坏重定向）要留痕');
    expect(block, contains('r456'), reason: '结论要带轮次，便于回溯');
    expect(
      block,
      contains('哈希搜索在这个口不可用'),
      reason: '哈希不可用要**明说**，否则下一轮容易标 supportsHash=true',
    );

    // ② 实现：类 + id + 默认源集合接线（"注释写了但没接线"= 假声明）
    expect(
      src,
      contains('class OpenSubtitlesRestSource implements SubtitleOnlineSource'),
      reason: '源必须真的实现接口，不能只写在注释里',
    );
    expect(src, contains("String get id => 'opensubtitles-rest';"));
    expect(
      src,
      contains('OpenSubtitlesRestSource(http: http)'),
      reason: '必须进 SubtitleSearchService.defaults（否则用户永远点不到）',
    );
    // ③ 全小写规则必须**在代码里**落地（不是只写在注释里）
    expect(
      src,
      contains('String _legacyQuerySegment(String title)'),
      reason: '查询段要有唯一入口函数（好审、好守）',
    );
    final fnStart = src.indexOf('String _legacyQuerySegment(String title)');
    final fn = src.substring(fnStart, (fnStart + 420).clamp(0, src.length));
    expect(
      fn,
      contains('toLowerCase()'),
      reason: '★ 大写 ⇒ 302：查询段必须 toLowerCase()',
    );
    expect(
      fn,
      contains(r'[^0-9a-z'),
      reason: '只留字母数字（点号/百分号编码同样撞坏 302）',
    );
  });
}
