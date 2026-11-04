// Audio Station 网络电台**列表页**（wave2）。
//
// 事实来源：`docs/audio-api-live.md` §1（2026-09-22 真机取证）+
// `docs/stage2-audio-download-api.md` §2.3 第 49 行（`webapi/AudioStation.api`）：
//   * `SYNO.AudioStation.Radio / list` v2（v1 也有 `list`）；
//   * path `AudioStation/radio.cgi`（来自 `SYNO.API.Info`；静态兜底见 `cgiPaths`）；
//   * root `data.radios`；真机逐字：
//     `{"radios":[{"id":"SHOUTcast","title":"SHOUTcast(TM)","type":"container","url":""},
//     {"id":"UserDefined",…}]}`。
//
// ★ 本页最重要的一条：**`type:"container"` 是分类容器，不是可播放电台项**
//   —— 真机首屏回的两条都是容器（`url` 为空）。官方前端把 `container` 映射成
//   目录图标、`station` 映射成电台图标（`audio-utils.js` 的 `createImgMapping`）。
//   这里把两者**分开渲染**：容器有独立 key/徽标、不可点；绝不当成电台条目。
//
// ★ 显示名一律用 `title`（真机容器 `id:"SHOUTcast"` / `title:"SHOUTcast(TM)"`）；
//   `id` 是内部值，**不上屏、不写进文件名**（硬要求）。
//
// ★★★ 第 392 轮（**DA32 的修法**）：容器展开 + 电台播放都接了。
//   权威取证（官方 Web 前端源码，离线可复算；SPK
//   `AudioStation-x86_64-7.2.1-6006.spk` sha256
//   `89d7e94207508d47bec7ed70541353b1b78ac8eff21fa7da4cc2065d2dc030c4`）：
//   * **展开参数是 `container`**（`audio-common.js` 逐字：
//     `api:"SYNO.AudioStation.Radio",method:"list",container:b,offset,library,text`）；
//   * 取值链 `null` → `SHOUTcast`（分类层）→ `SHOUTcast_<genre>`（分类叶子）
//     / `UserDefined` / `Favorite`（`audio-utils.js` 的 `_ShoutCast_ID="SHOUTcast"`
//     `_Userdefined_ID="UserDefined"` `_MyFavorite_ID="Favorite"` +
//     `isInShoutCast()` 判 `container.substr(0,9)==="SHOUTcast"`）；
//   * 电台项 `id` 以 `radio_` 开头（`isInetRadioItem()` 逐字），带非空 `url`。
//   ⇒ 容器行**可点**（进下一层），电台行**可点**（起播）。
//
// ⚠️ **就地订正**：此前注释里的"展开参数 = `type=player_source_*`"是错的 ——
//   `player_source_shoutcast|userdefined|def_radio_station` 是**本地化文案 key**
//   （`ajax_handler.cgi` / `audio-utils.js` 里都是 `_AST("player", …)` 的取值），
//   官方前端**从不发 `type`**。
//
// ⚠️ SHOUTcast 目录给的 `url` 常是 **`.pls` 播放列表**（分包
//   `etc/radio/shoutcast_<genre>.json` 逐字样本：
//   `http://yp.shoutcast.com/sbin/tunein-station.pls?id=…`）⇒ 起播前先用
//   `resolveRadioStreamUrl` 解析出真正的流地址（失败则回落原地址 + 可读原因）。
//
// ✅ **第 441 轮已接线**：`Radio.search`（关键字搜台，`DA95`）—— 根层 AppBar 的
//   搜索入口 + `AudioRadioSearchPage`；契约与实测读数见 `AudioStationApi.searchRadios`。
//   ⚠️ 顺带订正一个**假功能**：修前 `Radio.list` 收了个 `keyword` 参数，而服务端
//   **完全忽略**它（`keyword=Jazz` 与无参逐字同）⇒ 一旦接上 UI 就是"搜了等于没搜"。
//
// ✅ **第 137 轮已接线**（官方 `RadioEditor` 逐字取证）：
//   * `Radio.add` `{container, title, url, desc}` —— 新建自定义电台；
//   * `Radio.updateradios` —— 改名/删除。
//
// ⚠️⚠️ **就地订正（第 399 轮，DA46）**：`updateradios` 的载荷**不是**
//   "整段列表 + `radio_json`"（那是官方**安卓** `RadioEditor.java` 的形状，
//   服务端**不认这个键名**：真机回 `{}` 不报错，却把该段**清空** ⇒ 改名会
//   静默删掉电台，App 当时形状 `offset 0 / limit -1` 甚至**清空整个列表**）。
//   权威契约 = 官方 **Web 前端** `app/audio-common.js` 逐字：
//     * 改名：`{offset:<行号>, limit:1, radios_json:'[{"title","desc","url"}]'}`
//     * 删除：`{offset:<行号>, limit:1, radios_json:'[]'}`
//     * 记录**只有** `title/desc/url`（**无 `id`**）；语义是"替换这一段"。
//   真机对照读数见 `docs/android-ui-audit-r399.md` §S2。
//
// 三态（空 / 未安装·缺能力位 / 失败）复用 `AudioPagedBody`——
// 与音乐库各标签页同一套语义（未连接 / 套件未安装 / 无权限 / 网络 / 其它）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';

import '../../core/i18n/l10n.dart';
import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/user_facing_error.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/hud_widgets.dart';
import '../../data/dto/audio_station_dto.dart';
import '../media/audio_handler.dart';
import 'audio_labels.dart';
import 'audio_radio_failure.dart';
import 'audio_radio_icy.dart';
import 'audio_radio_player_sheet.dart';
import 'audio_page.dart';
import 'audio_providers.dart';
import 'audio_radio_selection.dart';
import 'audio_radio_stream.dart';

class AudioRadioPage extends ConsumerStatefulWidget {
  const AudioRadioPage({super.key, this.container, this.titleOverride});

  /// 要展开的容器（`null` = 根级容器列表）。
  ///
  /// 取值链：`SHOUTcast`（分类层）→ `SHOUTcast_<genre>` / `UserDefined` /
  /// `Favorite`（电台项列表）。证据见文件头注释。
  final String? container;

  /// 子页标题（用上级容器上屏的 `title`，**不用内部 id**）。
  final String? titleOverride;

  @override
  ConsumerState<AudioRadioPage> createState() => _AudioRadioPageState();
}

class _AudioRadioPageState extends ConsumerState<AudioRadioPage> {
  /// 引擎"起播失败"的订阅（第 393 轮修 **DA43**）。
  ///
  /// 为什么页面要自己听：`handler._onEngineError` 只对"会话过期"有动作，
  /// 其余失败**必须由发起播放的页面说出来** —— 真机缺陷就是这里静默
  /// （点了 `113.fm Blues Town` 没声、没提示）。
  StreamSubscription<AudioEngineFailure>? _failureSub;

  /// 最近一次请求起播的电台（"重试"要重播的就是它）。
  AudioRadioDto? _lastRequested;

  /// ★ r641（**DA234**）：**这条电台刚刚起播失败**（null = 没有失败）。
  ///
  /// 为什么不能只靠那条提示条：提示条 4 s 后自己消失，而"没播出来"是**持续**
  /// 事实 —— 用户放下手机再回来，看到的是一条写着"已暂停"、没有任何解释、
  /// 也没有重试入口的播放条（真机就是这个状态）。所以失败要**钉在播放条上**，
  /// 直到重试成功 / 换台 / 关掉。
  AudioRadioDto? _failedStation;

  /// 本页所在的容器（`null` = 根层的"容器列表"页）。
  String? get _container => widget.container;

  /// 本页是不是「自定义电台」页 —— **只有这一层**的行可以改名/删除。
  ///
  /// ★★ r400 真机缺陷 **DA47**：修前这里没有判容器，`My favorite radio` 与
  /// SHOUTcast 分类页的**每一行**都给了 `Edit`/`Delete`，而写动词的 `container`
  /// 却硬编码成 `UserDefined` ⇒ 在收藏页点"删除"，被删掉的是**同一个行号上的
  /// 自定义电台**（真机：`Favorite` 仍 2 条、`UserDefined` `1 → 0`，且无提示）。
  bool get _isUserDefined => _container == AudioRadioDto.containerUserDefined;

  /// 本页是不是「我的收藏」页（这一层的行只能"取消收藏"）。
  bool get _isFavorite => _container == AudioRadioDto.containerFavorite;

  /// 本页的查询（`container` 决定"看哪一层"；record 是 family 的键）。
  RadioQuery get _query => (
    container: widget.container,
    type: null,
    keyword: null,
    library: null,
  );

  /// ★★★ **r443**：多选集合（空集 = 非多选态）—— 网络电台「批量删除」。
  ///
  /// 只在**自定义电台页**（`_isUserDefined`）允许进入：服务端的批量删除就是
  /// `Radio/updateradios` 的**段替换**，而"哪一层"必须与本页的 `container`
  /// 一致（DA47 的教训：写动词的 container 错了就是在别的表上按同一个行号动手）。
  final Set<String> _selected = <String>{};

  bool get _selectionActive => _selected.isNotEmpty;

  /// 长按 / 点"多选"进入多选态；已在多选态时点击 = 反选。
  void _toggleSelected(String id) {
    setState(() {
      if (!_selected.add(id)) _selected.remove(id);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  /// 全选本页**已加载**的电台行（容器行不选）。
  void _selectAll(List<AudioRadioDto> items) {
    setState(() {
      _selected
        ..clear()
        ..addAll(items.where((r) => !r.isContainer).map((r) => r.id));
    });
  }

  /// 选中项 ⇒ **本页的服务端行号**（`items` 原样取下标，理由见 `_replaceRange`）。
  List<int> _selectedIndices(List<AudioRadioDto> items) => [
    for (var i = 0; i < items.length; i++)
      if (_selected.contains(items[i].id)) i,
  ];

  /// ★★★ **r443 批量删除**：把选中的行按**段**删掉（服务端是段替换语义）。
  ///
  /// 三条真机读数（`tool/r443_radio_batch_delete_probe_test.dart`）决定了这里的写法：
  /// ① 一次调用能删**一段连续多行**（`{offset, limit:n, radios_json:'[]'}`）；
  /// ② 删完之后**后面的行号前移** ⇒ 多段必须**从高往低**发（[radioDeleteCalls]）；
  /// ③ `limit` 越界会被服务端**钳到末尾**（不报错）；`limit:0` 会被**拒绝**（101）。
  Future<void> _deleteSelected(List<AudioRadioDto> items) async {
    final indices = _selectedIndices(items);
    if (indices.isEmpty) return;
    // 容器行绝不参与（本页理论上只有电台行，但判据要显式，别靠"应该"）。
    final containerIdx = <int>{
      for (var i = 0; i < items.length; i++)
        if (items[i].isContainer) i,
    };
    if (radioSelectionHitsContainer(indices, containerIdx)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(dataText('asRadioBatchDeleteTitle', '删除所选电台')),
        content: Text(
          dataText(
            'asRadioBatchDeleteBody',
            '确定删除所选的 {count} 个电台？此操作不可撤销。',
          ).replaceAll('{count}', '${indices.length}'),
        ),
        actions: [
          TextButton(
            key: const Key('as-radio-batch-delete-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(dataText('cancel', '取消')),
          ),
          TextButton(
            key: const Key('as-radio-batch-delete-ok'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(dataText('delete', '删除')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final api = ref.read(audioApiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final count = indices.length;
    try {
      // ★ 顺序 = 从高往低，一段一次调用（纯逻辑在 audio_radio_selection.dart，
      //   宿主用例逐段钉形状，真机再由探针钉服务端行为）。
      for (final (offset, limit) in radioDeleteCalls(indices)) {
        await api.updateRadios(
          container: AudioRadioDto.containerUserDefined,
          radiosJson: const [],
          offset: offset,
          limit: limit,
        );
      }
      if (!mounted) return;
      setState(_selected.clear);
      await _load(silent: true);
      messenger.showSnackBar(
        SnackBar(
          key: const Key('as-radio-batch-deleted'),
          content: Text(
            dataText('asRadioBatchDeleted', '已删除 {count} 个电台')
                .replaceAll('{count}', '$count'),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(userFacingError(e))),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _failureSub = ref
        .read(audioHandlerProvider)
        .engineFailures
        .listen(_onEngineFailure);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    unawaited(_failureSub?.cancel());
    _failureSub = null;
    super.dispose();
  }

  /// 引擎报"这条起播失败" → **说出来**（可读文案 + 重试），不再静默。
  ///
  /// 只对**本页刚点过的那条**提示：引擎的错误流是全 App 共享的，别把别的
  /// 页面/别的曲目的失败算到当前电台头上（陈旧提示 = 假信息）。
  void _onEngineFailure(AudioEngineFailure failure) {
    if (!mounted) return;
    final asked = _lastRequested;
    if (asked == null) return;
    if (failure.mediaId != null && failure.mediaId != asked.id) return;
    _notifyPlayFailure(asked);
  }

  /// "这个电台没能播"的**唯一**出口（两条路都走它，避免冒出两句不同的话）：
  ///
  /// * 引擎异步报错（`engineFailures`，例如 Extractor 读不出流）；
  /// * `startQueue` **直接抛**（just_audio 的 `load()` 是等"真的准备好"的
  ///   future，取流失败时它**也会**在几秒后以异常结束 ⇒ 上面的 catch）。
  ///
  /// ★ 真机教训（第 393 轮）：起播异常原先落到 `userFacingError(e)`，对未知异常
  ///   兜底成 `The operation could not be completed`（`errGenericFailed`）——
  ///   用户看到的是"某件事没成功"，**没有电台语义、也没有重试**；而且它会把
  ///   引擎那条好提示**顶掉**（谁后弹谁显示）。两条路必须同文案同动作。
  void _notifyPlayFailure(AudioRadioDto radio) {
    if (!mounted) return;
    // ★ r641（**DA234**）：失败态**钉在播放条上**（不止一条会消失的提示条），
    //   同时写进共享 provider —— 面板（弹层）要能读到同一个事实。
    ref.read(radioPlaybackFailureProvider.notifier).mark(radio.id);
    if (_failedStation?.id != radio.id) {
      setState(() => _failedStation = radio);
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    // ★ 真机缺陷（r641）：提示条**画在播放条上面**（两者都在底部）⇒
    //   播放条的暂停/展开/关闭三个键被盖住，想"换个台"都点不到。
    //   浮起来 + 让出播放条的高度即可（`as-radio-now-playing` 约 56 dp）。
    final barVisible =
        ref.read(audioHandlerProvider).mediaItem.value != null;
    messenger.showSnackBar(
      SnackBar(
        key: const Key('as-radio-play-failed'),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(12, 0, 12, barVisible ? 68 : 12),
        content: Text(asRadioPlayFailed),
        action: SnackBarAction(
          label: asRadioPlayRetry,
          onPressed: () => unawaited(_playStation(radio)),
        ),
      ),
    );
  }

  Future<void> _load({bool silent = false}) =>
      ref.read(audioRadioListProvider(_query).notifier).load(silent: silent);

  /// 进入下一层容器（容器行点击）。
  void _openContainer(AudioRadioDto radio) {
    // 标题只用 `title`；为空时退回"电台"徽标文案（**不回落到 id**）。
    final title = radio.title.isNotEmpty
        ? radio.title
        : asRadioStationBadge;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AudioRadioPage(container: radio.id, titleOverride: title),
      ),
    );
  }

  /// 起播一个电台项（`.pls`/`.m3u` 先解析出真正的流地址）。
  Future<void> _playStation(AudioRadioDto radio) async {
    _lastRequested = radio;
    // 新的起播请求 ⇒ 旧的失败态立刻作废（不许"边说没播边出声"）
    ref.read(radioPlaybackFailureProvider.notifier).clear();
    if (_failedStation != null && mounted) {
      setState(() => _failedStation = null);
    }
    // ★ 换了电台/点了重试 ⇒ 上一条"没能播放"的提示必须**立刻收掉**：
    //   真机踩到过 —— 提示条还挂在上一条上，而新点的电台已经出声了，
    //   于是屏幕上同时出现"没能播放"和真的在放（自相矛盾）。
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final handler = ref.read(audioHandlerProvider);
    final res = await resolveRadioStreamUrl(
      radio.url,
      http: ref.read(radioStreamHttpProvider),
    );
    if (!mounted) return;
    if (res.url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(asRadioLoadFailed)),
      );
      return;
    }
    // ★ 明文流要绕回环中继：Android release 档网络安全配置**只**给回环开明文，
    //   Media3/ExoPlayer 走系统策略 ⇒ 直连 `http://<公网IP>` 会被拒
    //   （真机逐字：`Cleartext HTTP traffic to 50.31.185.139 not permitted`）。
    final playable = await ref.read(radioStreamRelayProvider).playableUrl(res.url);
    if (!mounted) return;
    // 起播前把"地址从哪来、最终交给了谁"落进日志：真机复验时 `.pls` 有没有真被
    // 解析、明文流有没有走中继，只看这一行（`note`/`resolvedFromPlaylist`
    // 不是死字段 —— 这就是它们的读者）。
    debugPrint(
      '[audio-radio] play id=${radio.id} resolved=${res.resolvedFromPlaylist} '
      'note=${res.note.isEmpty ? '-' : res.note} relayed=${playable != res.url} '
      'url=${res.url} play=$playable',
    );
    try {
      final trackId = radio.id.isEmpty ? 'radio_${radio.title}' : radio.id;
      await handler.startQueue([
        AudioTrackInfo(
          id: trackId,
          url: playable,
          title: radio.title,
          artist: radio.desc,
          // ★ r633：显式标注"这是电台" ⇒ 全局迷你条点开的是电台面板，
          //   而不是去拉 `Song.getinfo`（那样只会得到一条空歌页）。
          kind: AudioTrackKind.radio,
        ),
      ]);
      // ★ r640（**DA233**）：起播成功后开一条**只读旁路**去问"这一首在播什么"
      //   （ICY `StreamTitle`）。读的是**已解析的真实流地址**（不是 `.pls`），
      //   失败只会少一行字，不影响播放。
      ref
          .read(radioNowPlayingProvider.notifier)
          .start(trackId, res.url);
    } catch (e) {
      // 电台起播失败 ⇒ 说人话 + 给重试（**不要** `userFacingError` 的通用兜底：
      // 真机读到的是 `The operation could not be completed`，等于没说）。
      debugPrint('[audio-radio] start failed id=${radio.id} err=$e');
      _notifyPlayFailure(radio);
    }
  }

  /// C5：新建自定义电台（`Radio/add`，参数逐字来自官方 `RadioEditor`）。
  Future<void> _addRadio(BuildContext context) async {
    final input = await _askRadio(context, title: context.t.audioRadioNew);
    if (input == null) return;
    final api = ref.read(audioApiProvider);
    if (api == null) return;
    try {
      await api.addRadio(
        container: AudioRadioDto.containerUserDefined,
        title: input.title,
        url: input.url,
        desc: input.desc,
      );
      await _load(silent: true);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(userFacingError(e))),
        );
      }
    }
  }

  /// C5：改名（`Radio/updateradios` 段替换，段长 1）。
  Future<void> _editRadio(BuildContext context, AudioRadioDto radio) async {
    final input = await _askRadio(
      context,
      title: context.t.audioRadioEdit,
      initial: radio,
    );
    if (input == null || !context.mounted) return;
    await _replaceRange(
      context,
      container: AudioRadioDto.containerUserDefined,
      radio: radio,
      value: input,
    );
  }

  /// ★ r400：把某个电台**加入收藏**（官方 Web 前端"加入收藏"逐字）。
  ///
  /// `{method:"updateradios", container:"Favorite", offset:-1, limit:0, radios_json:[…]}`
  /// —— 真机对照过：`offset:-1 / limit:0` 是"追加"，回包 `{}`，`Favorite total 0→1`。
  /// ⚠️ 服务端**不去重**：同一条再加一次就是两条（本轮真机实测）。
  Future<void> _addToFavorites(BuildContext context, AudioRadioDto radio) =>
      addRadioToFavorites(ref, context, radio);

  /// ★ r400：把某条收藏**取消**（与 UserDefined 同一套**段替换**语义）。
  ///
  /// 真机对照：`{container:"Favorite", offset:<行号>, limit:1, radios_json:'[]'}`
  /// ⇒ 回 `{}`、`Favorite total 1→0`（而 `offset:-1/limit:0` 去删会回 `101`）。
  Future<void> _removeFromFavorites(
    BuildContext context,
    AudioRadioDto radio,
  ) async {
    await _replaceRange(
      context,
      container: AudioRadioDto.containerFavorite,
      radio: radio,
      remove: true,
    );
  }

  /// C5：删除（`Radio/updateradios` 段替换：这一段替换成**空**）。
  Future<void> _deleteRadio(BuildContext context, AudioRadioDto radio) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(dataText('asRadioDeleteTitle', '删除电台')),
        content: Text(context.t.audioRadioDeleteBody(radio.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(dataText('cancel', '取消')),
          ),
          TextButton(
            key: const Key('as-radio-delete-ok'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(dataText('delete', '删除')),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await _replaceRange(
      context,
      container: AudioRadioDto.containerUserDefined,
      radio: radio,
      remove: true,
    );
  }

  /// 把自定义电台列表里**第 `index` 行**替换成 [value]（改名）或替换成空（删除）。
  ///
  /// ★ 官方 Web 前端（`audio-common.js`）逐字是"**段替换**"：
  /// `offset = 页偏移 + 行号`、`limit = 段长`、`radios_json` = 这一段的**新内容**
  /// （记录**只有** `title/desc/url`，**不带 `id`**）。我们只做单行动作 ⇒
  /// 段长恒为 1、段内新内容要么是 1 条（改名）要么是 0 条（删除）。
  ///
  /// ⚠️ `offset` 必须用**服务端行号**：本页从 `offset 0` 起加载、`loadMore`
  /// 只往后追加 ⇒ 已加载列表的下标 = 服务端下标。
  Future<void> _replaceRange(
    BuildContext context, {
    required String container,
    required AudioRadioDto radio,
    AudioRadioInput? value,
    bool remove = false,
  }) async {
    // ★ 写动词的 `container` 必须**与本页一致**（DA47）：不然就是在别的列表里
    //   按同一个行号改数据 —— 用户看到的是"删收藏"，实际删的是自定义电台。
    assert(
      container == _container,
      '写动词的 container($container) 必须等于本页 container($_container)',
    );
    final api = ref.read(audioApiProvider);
    if (api == null) return;
    // ★★ 必须读**本页自己**的那个 family 实例（`_query`，键里有 `container`）。
    //   r399 真机复验当场抓到：写 `allRadiosQuery`（`container: null` = 根层）读的是
    //   **另一个**实例 ⇒ 拿到的 items 是空（或容器行）⇒ 行号 `-1` 静默 return，
    //   而修前那版更糟：它把"空数组"当整段回传 ⇒ **整个自定义列表被清空**。
    final items = ref.read(audioRadioListProvider(_query)).items;
    // ★★ 行号必须取**服务端行序**（`items` 原样，**不要**先 `where(!isContainer)`）：
    //   `updateradios` 的 `offset` 是"该 container 下第几行"，而列表页的容器行
    //   （`type:"container"`，如根层的三个、`SHOUTcast` 下的 26 个分类）**同样占行号**。
    //   修前这里先过滤掉容器行再取下标 ⇒ 一旦某个容器页**混着**容器行与电台行，
    //   过滤后的下标就会**小于**服务端下标 —— 那就是"删第 k 行却删到别的一条"，
    //   与 DA47（错容器）同族，只是从"错表"换成"错行"。真机取证见
    //   `tool/probe_r401_radio_mix.dart`：本 NAS 三种页面**当前都不混**（根层 3 行全容器、
    //   `SHOUTcast` 26 行全容器、分类叶子 50 行全电台、`UserDefined`/`Favorite` 全电台），
    //   ⇒ 这是**潜伏隐患的结构性加固**，不是已触发的缺陷。
    final index = items.indexWhere((r) => r.id == radio.id);
    if (index < 0) return;
    assert(
      !items[index].isContainer,
      '写动词的行必须落在电台行上，不能落在容器行（${items[index].id}）',
    );
    final json = <Map<String, dynamic>>[
      if (!remove && value != null)
        {'title': value.title, 'desc': value.desc, 'url': value.url},
    ];
    try {
      await api.updateRadios(
        container: container,
        radiosJson: json,
        offset: index,
        limit: 1,
      );
      await _load(silent: true);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(userFacingError(e))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(audioRadioListProvider(_query));
    // ★ r633（DA216）：列表要标出"正在播的那一条"，并让点当前台 = 暂停。
    //   状态只读全局 `audioHandler`（不另存一份 bool），且**只认 `kind == radio`**
    //   —— 别处点开的歌不许在这里被画成电台（DA216 反向判据）。
    final handler = ref.watch(audioHandlerProvider);
    final body = StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      initialData: handler.mediaItem.value,
      builder: (context, itemSnap) {
        final item = itemSnap.data;
        final isRadio = item != null &&
            AudioTrackKind.fromTag(item.extras?['kind']) == AudioTrackKind.radio;
        final currentId = isRadio ? item.id : null;
        final playingNow = isRadio && handler.playbackState.value.playing;
        return AudioPagedBody<AudioRadioDto>(
      kind: null, // 电台不属于音乐库分类 → 用本页自己的空态文案
      state: state,
      emptyTitle: asRadioEmpty,
      errorTitle: asRadioLoadFailed,
      onLoad: _load,
      onLoadMore: () =>
          ref.read(audioRadioListProvider(_query).notifier).loadMore(),
      onRefresh: () => _load(silent: true),
      itemBuilder: (context, radio) => _RadioTile(
        key: Key(
          radio.isContainer
              ? 'as-radio-container-${radio.id}'
              : 'as-radio-station-${radio.id}',
        ),
        radio: radio,
        // ★ r633（DA216）：当前台标记 + 点当前台 = 暂停（不是重新起播）。
        current: currentId != null && currentId == radio.id,
        playing: playingNow,
        // ★ r443：多选态（只在自定义电台页进入）—— 行左侧给勾选框，点行 = 反选。
        selectable: _isUserDefined && !radio.isContainer,
        selected: _selected.contains(radio.id),
        onLongPress: _isUserDefined && !radio.isContainer
            ? () => _toggleSelected(radio.id)
            : null,
        // 容器行：进下一层（`container` 展开，官方前端逐字）。
        onOpen: radio.isContainer ? () => _openContainer(radio) : null,
        // 电台行：起播（`.pls` 先解析）。容器不是电台项 ⇒ 不给播放入口。
        // ★ 多选态下点按 = 反选（不许一边选一边播 —— 那是两个意思一个手势）。
        onPlay: _selectionActive
            ? (radio.isContainer ? null : () => _toggleSelected(radio.id))
            : (radio.isStation
                  ? () => currentId == radio.id
                        ? handler.pause().catchError((Object _) {})
                        : _playStation(radio)
                  : null),
        // ★ 改名/删除**只在自定义电台页**给（写动词的 container 也是 UserDefined）。
        //   多选态下收起行菜单：免得"删一条"和"删所选"两个删除动作同时在场。
        onEdit: _isUserDefined && !radio.isContainer && !_selectionActive
            ? () => _editRadio(context, radio)
            : null,
        onDelete: _isUserDefined && !radio.isContainer && !_selectionActive
            ? () => _deleteRadio(context, radio)
            : null,
        // ★ 收藏页给"取消收藏"，其余页给"加入收藏"（官方 Web 前端两套形状）。
        onUnfavorite: _isFavorite && !radio.isContainer
            ? () => _removeFromFavorites(context, radio)
            : null,
        onFavorite: !_isFavorite && !radio.isContainer && radio.hasStreamUrl
            ? () => _addToFavorites(context, radio)
            : null,
        ),
      );
      },
    );
    return DesignScaffold(
      appBar: AppBar(
        title: Text(widget.titleOverride ?? asRadioTitle),
        actions: [
          // ★★★ r443：**多选态**的顶栏（只在自定义电台页进入）——
          //   全选/取消全选 + 退出；"删除所选"在**底部条**上（破坏性动作离手远一点）。
          if (_selectionActive) ...[
            IconButton(
              key: const Key('as-radio-select-all'),
              tooltip: state.items.every((r) => r.isContainer || _selected.contains(r.id))
                  ? dataText('asRadioSelectNone', '取消全选')
                  : dataText('asRadioSelectAll', '全选'),
              icon: Icon(
                state.items.every((r) => r.isContainer || _selected.contains(r.id))
                    ? Icons.deselect
                    : Icons.select_all,
              ),
              onPressed: () {
                final all = state.items.every(
                  (r) => r.isContainer || _selected.contains(r.id),
                );
                if (all) {
                  _clearSelection();
                } else {
                  _selectAll(state.items);
                }
              },
            ),
            IconButton(
              key: const Key('as-radio-selection-cancel'),
              tooltip: dataText('asRadioSelectNone', '取消全选'),
              icon: const Icon(Icons.close),
              onPressed: _clearSelection,
            ),
          ],
          // ★ r443：「多选」入口（长按也能进；入口只在**自定义电台页**给）。
          if (!_selectionActive && _isUserDefined)
            IconButton(
              key: const Key('as-radio-select-mode'),
              tooltip: dataText('asRadioSelectMode', '多选'),
              icon: const Icon(Icons.checklist),
              onPressed: () {
                final first = state.items.where((r) => !r.isContainer);
                if (first.isNotEmpty) _toggleSelected(first.first.id);
              },
            ),
          // ★ r441：**关键字搜台**入口 —— 只在**根层**给（`Radio.search` 是
          //   SHOUTcast 目录级搜索，真机实测 `container` 被服务端**忽略**，
          //   所以在分类/收藏页给入口只会误导）。搜出来的是**电台项**（有 `url`）。
          if (_container == null)
            IconButton(
              key: const Key('as-radio-search'),
              tooltip: asRadioSearchTitle,
              icon: const Icon(Icons.search),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AudioRadioSearchPage(),
                ),
              ),
            ),
          // ★ `Radio/add` 的 container 也是 UserDefined ⇒ 只在根层/自定义页给入口，
          //   免得在收藏页点"新建电台"却出现在另一个列表里（r400 一并收口）。
          if (_container == null || _isUserDefined)
            IconButton(
              key: const Key('as-radio-add'),
              tooltip: dataText('asRadioAdd', '新建电台'),
              icon: const Icon(Icons.add),
              onPressed: () => _addRadio(context),
            ),
        ],
      ),
      // 有内容时才挂"只列表、不播放"的如实说明（空态/失败态不叠噪声）。
      body: state.items.isEmpty
          ? body
          : Column(
              children: [
                const _RadioListNote(),
                Expanded(child: body),
                // ★ 用户原话：「电台页没有播放器」——起播后这一页什么都不显示，
                //   想暂停/关掉只能退出页面去别处找 ⇒ 起播后在这一页挂一条播放条。
                _RadioNowPlayingBar(
                  failedId: _failedStation?.id,
                  onRetry: _failedStation == null
                      ? null
                      : () => unawaited(_playStation(_failedStation!)),
                ),
                // ★ r443：多选态下的批量操作条（与歌曲页同形）。
                if (_selectionActive)
                  _RadioSelectionBar(
                    count: _selected.length,
                    onCancel: _clearSelection,
                    onDelete: () => _deleteSelected(state.items),
                  ),
              ],
            ),
    );
  }
}

/// 电台新建/编辑的输入（`Radio.add` 的 `title`/`url`/`desc`）。
class AudioRadioInput {
  const AudioRadioInput({
    required this.title,
    required this.url,
    this.desc = '',
  });

  final String title;
  final String url;
  final String desc;
}

/// 新建/编辑对话框（三个字段：名称 / URL / 描述）。
Future<AudioRadioInput?> _askRadio(
  BuildContext context, {
  required String title,
  AudioRadioDto? initial,
}) {
  final titleCtrl = TextEditingController(text: initial?.title ?? '');
  final urlCtrl = TextEditingController(text: initial?.url ?? '');
  final descCtrl = TextEditingController(text: initial?.desc ?? '');
  final formKey = GlobalKey<FormState>();
  return showDialog<AudioRadioInput>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      // ★★★ r443（`DA97`）：**名称与 URL 都必填**。
      //
      // 为什么必须自己拦：真机读数（`tool/r443_radio_batch_delete_probe_test.dart` E 段）
      // ——`Radio.add {title:"", url:""}` **服务端照收**（不报错），列表里就多出
      // 一条 `id="radio_"` / `title=""` / `url=""` 的**死行**：没有名字、点不动、
      // 也不能播。服务端不给的错误必须由我们给。
      content: Form(
        key: formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const Key('as-radio-title-field'),
              controller: titleCtrl,
              autofocus: true,
              decoration: InputDecoration(labelText: context.t.fieldName),
              validator: (v) => (v ?? '').trim().isEmpty
                  ? dataText('asRadioNameRequired', '请填写电台名称')
                  : null,
            ),
            TextFormField(
              key: const Key('as-radio-url-field'),
              controller: urlCtrl,
              decoration: const InputDecoration(labelText: 'URL'),
              validator: (v) => (v ?? '').trim().isEmpty
                  ? dataText('asRadioUrlRequired', '请填写电台地址（URL）')
                  : null,
            ),
            TextFormField(
              key: const Key('as-radio-desc-field'),
              controller: descCtrl,
              decoration: InputDecoration(labelText: context.t.fieldDescription),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('as-radio-cancel'),
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(dataText('cancel', '取消')),
        ),
        TextButton(
          key: const Key('as-radio-ok'),
          onPressed: () {
            // 校验不过就**留在对话框里**（把原因写在字段下面），不许关掉当成功。
            if (!(formKey.currentState?.validate() ?? false)) return;
            Navigator.of(ctx).pop(
              AudioRadioInput(
                title: titleCtrl.text.trim(),
                url: urlCtrl.text.trim(),
                desc: descCtrl.text.trim(),
              ),
            );
          },
          child: Text(dataText('ok', '确定')),
        ),
      ],
    ),
  );
}

/// 页内说明：这一层能做什么（第 392 轮起**真的能播**，所以文案不再是
/// "暂未提供播放"；仍如实说明 SHOUTcast 目录的地址要先解析播放列表）。
class _RadioListNote extends StatelessWidget {
  const _RadioListNote();

  @override
  Widget build(BuildContext context) {
    // 设计稿里说明文字是一张说明卡（会自动换行）。
    // 原来单行 `TelemetryLabel` 在真机上被截成 `…tap a station to start…` ——
    // 一半信息读不到（"只列表、不播放"这个关键说明正好在截断处）。
    return KeyedSubtree(
      key: const Key('as-radio-note'),
      child: DesignNote(asRadioListNote, icon: Icons.info_outline),
    );
  }
}

/// 一条电台记录：**容器**与**电台项**分开渲染。
class _RadioTile extends StatelessWidget {
  const _RadioTile({
    super.key,
    required this.radio,
    this.onOpen,
    this.onPlay,
    this.onEdit,
    this.onDelete,
    this.onFavorite,
    this.onUnfavorite,
    this.selectable = false,
    this.selected = false,
    this.onLongPress,
    this.current = false,
    this.playing = false,
  });

  /// ★ r633（DA216）：这一行是不是**正在播的那一条**。
  ///
  /// 真机现场：电台在播时列表里**没有任何标记**，用户不知道哪一行是当前台；
  /// 点同一台还会重新起播（而不是暂停）。判据来自全局 `audioHandler.mediaItem`
  /// （唯一状态源），`kind == radio` 才算 —— 别处点的歌不许被画成电台（DA216 ②）。
  final bool current;

  /// 正在播 + 是否真在出声（决定行尾图标是"暂停"还是"播放"）。
  final bool playing;

  final AudioRadioDto radio;

  /// ★ r443：这一行**能不能被多选**（只有自定义电台页的电台行为 true）。
  final bool selectable;

  /// ★ r443：这一行**当前选没选中**（多选态下左侧显示勾选框）。
  final bool selected;

  /// ★ r443：长按进入多选（官方 APK adapter 层的多选同语义）。
  final VoidCallback? onLongPress;

  /// 容器行：进下一层（`container` 展开）。
  final VoidCallback? onOpen;

  /// 电台行：起播。
  final VoidCallback? onPlay;

  /// 只有「自定义电台」页给（容器行/其它容器页为 null）。
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  /// 「加入收藏」/「取消收藏」（两页互斥；容器行为 null）。
  final VoidCallback? onFavorite;
  final VoidCallback? onUnfavorite;

  @override
  Widget build(BuildContext context) {
    // ★ 标题只用 `title`；**绝不**回落到 `id`（内部值不上屏）。
    final title = radio.title.isNotEmpty ? radio.title : asRadioStationBadge;
    if (radio.isContainer) {
      return DesignRowTile(
        key: Key('as-radio-container-tile-${radio.id}'),
        // ★ r631：图标改为**显式**取调色板主色（原来是 Material 默认色）。
        //   ⚠️ 实测：本页 `DesignPalette.of(context).primary` 解析出来仍是全局蓝
        //   (42,77,208)，而音乐页是深青 (51,99,131) —— 同一个 App 两个模块两种
        //   主色。这是**既有的主题接线问题**（不是本轮引入），已写进
        //   `docs/android-ui-audit-r631.md` §8 诚实缺口，不在本轮盲改全局主题。
        leading: Icon(
          Icons.folder_outlined,
          color: DesignPalette.of(context).primary,
        ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        // ★ r633（DA216）：不再给每行挂一句 `Radio category` 这种填充词 ——
        //   一层里所有行都写同一句，等于没写；容器身份已经由文件夹图标 + `>` 表达。
        // 容器展开参数 = `container`（官方前端逐字）⇒ 真的能进下一层。
        onTap: onOpen,
        trailing: onOpen == null
            ? null
            : const Icon(Icons.chevron_right, size: 18),
      );
    }
    // ★ r633（DA216）：副标题 = 「状态词（仅当前台） · 人话描述（有才写）」；
    //   两段都空 ⇒ 不挂副标题（不再用 `Station` 这种填充词占位）。
    final humanDesc = asRadioHumanDesc(radio.desc);
    final stateWord = current
        ? (playing
              ? dataText('asRadioNowPlaying', '正在播放')
              : dataText('asRadioPaused', '已暂停'))
        : '';
    final joined = [stateWord, humanDesc]
        .where((e) => e.isNotEmpty)
        .join(' · ');
    final String? radioSubtitleText = joined.isEmpty ? null : joined;
    return DesignRowTile(
      key: Key('as-radio-station-tile-${radio.id}'),
      // ★ r443：可选时（多选支撑面）左侧是勾选框；未进入多选态也画出来，
      //   否则"长按能多选"就只存在于文档里（发现性 = 0）。
      leading: selectable
          ? Checkbox(
              key: Key('as-radio-check-${radio.id}'),
              value: selected,
              onChanged: onLongPress == null ? null : (_) => onLongPress!(),
            )
          // ★ r633（DA216）：正在播的那一行给**有声波**图标（不是又一行同样的
          //   收音机图标）——"哪一条在响"必须一眼可见。用 `KeyedSubtree` 挂键：
          //   直接挂在 `Icon` 上时，`DesignRowShell` 内部重建会把它吞掉
          //   （实测 `find.byKey` 找不到、`Icon.key` 恒为 null）。
          : (current
                ? KeyedSubtree(
                    key: Key('as-radio-current-${radio.id}'),
                    child: Icon(
                      Icons.graphic_eq,
                      color: DesignPalette.of(context).primary,
                    ),
                  )
                : Icon(
                    Icons.radio_outlined,
                    color: DesignPalette.of(context).primary,
                  )),
      selected: selected,
      onLongPress: onLongPress,
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: current
            ? TextStyle(
                fontWeight: FontWeight.w700,
                color: DesignPalette.of(context).primary,
              )
            : null,
      ),
      // ★ r631：副标题只说人话。目录里大量电台的 `desc` 就是 `MP3 (192 kbps)`
      //   这种编码串 —— 用户 2026-10-23「很多音频技术参数没有必要罗列在界面上」
      //   ⇒ 摘掉技术片段。
      // ★ r633（DA216）：摘完没人话就**不挂副标题**（旧版回落到一句 `Station`，
      //   整页每一行都是同一句等于没写）。正在播的那一行把状态词写在最前。
      subtitle: radioSubtitleText == null
          ? null
          : Text(
              radioSubtitleText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      // 有可播地址才给 onTap（没有地址仍不给死入口）。
      onTap: radio.hasStreamUrl || radio.id.startsWith('radio_') ? onPlay : null,
      trailing: (onEdit == null &&
              onDelete == null &&
              onFavorite == null &&
              onUnfavorite == null)
          ? null
          : PopupMenuButton<String>(
              key: Key('as-radio-menu-${radio.id}'),
              onSelected: (v) => switch (v) {
                'edit' => onEdit!(),
                'delete' => onDelete!(),
                'favorite' => onFavorite!(),
                _ => onUnfavorite!(),
              },
              itemBuilder: (_) => [
                if (onEdit != null)
                  PopupMenuItem(
                    key: Key('as-radio-edit-${radio.id}'),
                    value: 'edit',
                    child: Text(dataText('asRadioEdit', '编辑')),
                  ),
                if (onDelete != null)
                  PopupMenuItem(
                    key: Key('as-radio-delete-${radio.id}'),
                    value: 'delete',
                    child: Text(dataText('delete', '删除')),
                  ),
                if (onFavorite != null)
                  PopupMenuItem(
                    key: Key('as-radio-fav-${radio.id}'),
                    value: 'favorite',
                    child: Text(dataText('asRadioFavAdd', '加入收藏')),
                  ),
                if (onUnfavorite != null)
                  PopupMenuItem(
                    key: Key('as-radio-unfav-${radio.id}'),
                    value: 'unfavorite',
                    child: Text(dataText('asRadioFavRemove', '取消收藏')),
                  ),
              ],
            ),
    );
  }
}


/// ★★★ **r443**：多选态下的批量操作条（与歌曲页 `_SongSelectionBar` 同形）。
///
/// 只有**一个**破坏性动作（删除所选）⇒ 放底部、离手远一点；顶栏留给"全选/退出"。
/// 电台页的"正在播放"条（用户 r468 反馈：电台页没有播放器）。
///
/// 状态**只**读 `audioHandler`（`playbackState` + `mediaItem`），不自己维护一份
/// 可能与真实播放脱节的 bool —— 这与 hp 的单一状态源约定一致。
/// 没在播任何东西时整条不出现（不占位、不假装）。
/// 电台页底部的**正在播放条**（r631 重做）。
///
/// 用户 2026-10-23：「音频，包括音乐与电台播放器也需要重新设计，从人类用户使用
/// 角度……很多音频技术参数没有必要罗列在界面上」。
///
/// 旧版：一行小字 `Blues Radio` + `MP3 (192 kbps)`（码率直接当副标题画在界面上）
/// + 暂停 + 关闭。缺"点开看/调"的入口 —— 想看清电台、想复制地址，都没有地方去。
///
/// 新版：
///   * 左边一个**电台图标块**（不是行首小图标），中间是电台名 + **人话**副标题
///     （`正在播放` / `已暂停`；码率等留在「电台信息」里）；
///   * 右侧：播放/暂停、**展开**（进播放器面板）、停止；
///   * 点标题区域同样展开 —— 整条卡片都是"看这个电台"的入口。
///
/// 键名一个没改（`as-radio-now-playing` / `-toggle` / `-close`）：旧用例仍成立。
class _RadioNowPlayingBar extends ConsumerWidget {
  const _RadioNowPlayingBar({this.failedId, this.onRetry});

  /// 刚起播失败的电台 id（与当前条目的 `MediaItem.id` 相同才显示失败态）。
  final String? failedId;

  /// 重试回调（由页面提供 —— 只有页面手里有那条电台的 DTO）。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.watch(audioHandlerProvider);
    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      initialData: handler.mediaItem.value,
      builder: (context, itemSnap) {
        final item = itemSnap.data;
        if (item == null) return const SizedBox.shrink();
        return StreamBuilder<PlaybackState>(
          stream: handler.playbackState,
          initialData: handler.playbackState.value,
          builder: (context, stateSnap) {
            final state = stateSnap.data;
            // ★ `stop()` 之后 `mediaItem` 不一定被清空（audio_service 只把
            //   processingState 打到 idle）⇒ 只看 mediaItem 会留下一条
            //   "在播"的假信息（用例②就是抓这个）。idle = 没有在播。
            if (state == null ||
                state.processingState == AudioProcessingState.idle) {
              return const SizedBox.shrink();
            }
            final playing = state.playing;
            final p = DesignPalette.of(context);
            // ★ r641：这条是不是刚失败的那条（按 id 比，别把别的失败算过来）
            final failed = failedId != null && failedId == item.id;
            void open() => showRadioPlayerSheet(
                  context,
                  item: item,
                  onRetry: failed ? onRetry : null,
                );
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: Container(
                key: const Key('as-radio-now-playing'),
                padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                decoration: BoxDecoration(
                  color: p.surface,
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: p.line),
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: InkWell(
                        key: const Key('as-radio-now-playing-open'),
                        borderRadius: BorderRadius.circular(10),
                        onTap: open,
                        child: Row(
                          children: <Widget>[
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: p.primarySoft,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.radio,
                                size: 22,
                                color: p.primary,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Text(
                                    item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: p.text,
                                    ),
                                  ),
                                  Text(
                                    // ★ r641（**DA234**）：失败时副标题说人话，
                                    //   并保持到重试/换台 —— 不许只剩一个"已暂停"。
                                    failed
                                        ? dataText(
                                            'asRadioPlayFailedShort',
                                            '没能播放',
                                          )
                                        : asRadioPlayingStateText(
                                            playing: playing,
                                            desc: item.artist ?? '',
                                          ),
                                    key: const Key('as-radio-now-playing-subtitle'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 11.5, color: p.muted),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('as-radio-now-playing-toggle'),
                      tooltip: playing ? context.t.asPause : context.t.asPlay,
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      color: p.text,
                      onPressed: () => playing ? handler.pause() : handler.play(),
                    ),
                    if (failed)
                      IconButton(
                        key: const Key('as-radio-now-playing-retry'),
                        tooltip: asRadioPlayRetry,
                        icon: const Icon(Icons.refresh, size: 20),
                        color: p.primary,
                        onPressed: onRetry,
                      ),
                    IconButton(
                      key: const Key('as-radio-now-playing-expand'),
                      tooltip: dataText('asRadioOpenPlayer', '打开播放器'),
                      icon: const Icon(Icons.keyboard_arrow_up, size: 22),
                      color: p.muted,
                      onPressed: open,
                    ),
                    IconButton(
                      key: const Key('as-radio-now-playing-close'),
                      tooltip: context.t.asClosePlayer,
                      icon: const Icon(Icons.close, size: 20),
                      color: p.muted,
                      onPressed: () {
                        // r640：关掉播放条 = 不再有"正在播的曲目"，探针也一起停
                        ref.read(radioNowPlayingProvider.notifier).stop();
                        // r641：关掉播放条 = 这条不再"没播出来"
                        ref.read(radioPlaybackFailureProvider.notifier).clear();
                        handler.stop();
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _RadioSelectionBar extends StatelessWidget {
  const _RadioSelectionBar({
    required this.count,
    required this.onCancel,
    required this.onDelete,
  });

  final int count;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('as-radio-selection-bar'),
      color: Theme.of(context).colorScheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.md,
            vertical: Gap.sm,
          ),
          child: Row(
            children: [
              IconButton(
                key: const Key('as-radio-selection-bar-cancel'),
                tooltip: dataText('asRadioSelectNone', '取消全选'),
                icon: const Icon(Icons.close),
                onPressed: onCancel,
              ),
              TelemetryLabel(
                dataText('asRadioSelectionCount', '已选 {count}').replaceAll(
                  '{count}',
                  '$count',
                ),
                size: 12,
                color: DesignPalette.of(context).dim,
              ),
              const Spacer(),
              TextButton.icon(
                key: const Key('as-radio-batch-delete'),
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline, size: 20),
                label: Text(dataText('asRadioBatchDelete', '删除所选')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// **加入收藏**（`Radio/updateradios`，`container:"Favorite"` ＋ `offset:-1&limit:0`
/// = 官方前端"追加一条"的形状）。
///
/// ★ r441 抽成顶层：**搜索页与列表页必须走同一条写动词路径**（复制一份迟早分叉）。
Future<void> addRadioToFavorites(
  WidgetRef ref,
  BuildContext context,
  AudioRadioDto radio,
) async {
  final api = ref.read(audioApiProvider);
  if (api == null) return;
  try {
    await api.updateRadios(
      container: AudioRadioDto.containerFavorite,
      radiosJson: [
        {'title': radio.title, 'desc': radio.desc, 'url': radio.url},
      ],
      offset: -1,
      limit: 0,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(dataText('asRadioFavAdded', '已加入收藏'))),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFacingError(e))),
      );
    }
  }
}

/// ★ r441：网络电台**关键字搜台**页（`Radio.search` v2，只读取证的契约见
/// [AudioStationApi.searchRadios]）。
///
/// 与"歌曲搜索页"同一套交互形状（`AppBar` 里放 `TextField` ＋ 放大镜提交），
/// 但**通道不同**：歌曲＝`Song.search`，电台＝`Radio.search`。
///
/// ★ 三条如实边界（都在真机上量过）：
/// 1. 关键字**不能空** —— 服务端无 `keyword` 直接回 `101 请求无效`（不是"回全部"）；
/// 2. 结果由 SHOUTcast 目录给出，**慢**（真机 0.8–10.3 s/次），所以进页先给提示、
///    提交后给加载态，**不**自动重试；
/// 3. `total` 是服务端**封顶**的命中数（实测 500），分页仍按 `offset/limit` 往后取。
class AudioRadioSearchPage extends ConsumerStatefulWidget {
  const AudioRadioSearchPage({super.key});

  @override
  ConsumerState<AudioRadioSearchPage> createState() =>
      _AudioRadioSearchPageState();
}

class _AudioRadioSearchPageState extends ConsumerState<AudioRadioSearchPage> {
  final _controller = TextEditingController();
  RadioQuery? _query;
  AudioRadioDto? _lastRequested;
  StreamSubscription<AudioEngineFailure>? _failureSub;

  @override
  void initState() {
    super.initState();
    // 与列表页同一条"起播失败要说出来"的路（引擎的错误流是全 App 共享的 ⇒
    // 只认**本页刚点过的那条**，别把别处的失败算到搜索结果头上）。
    _failureSub = ref
        .read(audioHandlerProvider)
        .engineFailures
        .listen((f) {
      if (!mounted) return;
      final asked = _lastRequested;
      if (asked == null) return;
      if (f.mediaId != null && f.mediaId != asked.id) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          key: const Key('as-radio-play-failed'),
          content: Text(asRadioPlayFailed),
          action: SnackBarAction(
            label: asRadioPlayRetry,
            onPressed: () => unawaited(_play(asked)),
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    unawaited(_failureSub?.cancel());
    _failureSub = null;
    _controller.dispose();
    super.dispose();
  }

  void _submit(String raw) {
    final kw = raw.trim();
    // ★ 空关键字**不发**（服务端 `101`）—— 与"清空输入框"同义，保留上一次结果。
    if (kw.isEmpty) return;
    final q = radioSearchQuery(kw);
    if (q == _query) return;
    setState(() => _query = q);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(audioRadioListProvider(q).notifier).load();
      }
    });
  }

  /// 起播（与列表页同一条路径：`.pls`/`.m3u` 先解析 + 明文走回环中继）。
  Future<void> _play(AudioRadioDto radio) async {
    _lastRequested = radio;
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final handler = ref.read(audioHandlerProvider);
    final res = await resolveRadioStreamUrl(
      radio.url,
      http: ref.read(radioStreamHttpProvider),
    );
    if (!mounted) return;
    if (res.url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(asRadioLoadFailed)),
      );
      return;
    }
    final playable = await ref
        .read(radioStreamRelayProvider)
        .playableUrl(res.url);
    if (!mounted) return;
    try {
      final trackId = radio.id.isEmpty ? 'radio_${radio.title}' : radio.id;
      await handler.startQueue([
        AudioTrackInfo(
          id: trackId,
          url: playable,
          title: radio.title,
          artist: radio.desc,
          // ★ r633：显式标注"这是电台" ⇒ 全局迷你条点开的是电台面板，
          //   而不是去拉 `Song.getinfo`（那样只会得到一条空歌页）。
          kind: AudioTrackKind.radio,
        ),
      ]);
      // ★ r640（**DA233**）：起播成功后开一条**只读旁路**去问"这一首在播什么"
      //   （ICY `StreamTitle`）。读的是**已解析的真实流地址**（不是 `.pls`），
      //   失败只会少一行字，不影响播放。
      ref
          .read(radioNowPlayingProvider.notifier)
          .start(trackId, res.url);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            key: const Key('as-radio-play-failed'),
            content: Text(asRadioPlayFailed),
            action: SnackBarAction(
              label: asRadioPlayRetry,
              onPressed: () => unawaited(_play(radio)),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(audioApiProvider);
    // ★ 只有 v1 的服务器上，`Radio.search` 会回 `103`（真机只读取证）⇒ 如实说
    //   "不支持"，别让用户点了半天只看到"加载失败"。能力表未知时**不**下这个结论。
    final unsupported = api != null && !api.supportsRadioSearch;
    final q = _query;
    // ★ v1-only 的服务器上**根本不进结果视图**：`AudioPagedBody` 的"未安装/无权限"
    //   空态会把"这台 NAS 没有 search 方法"说成别的意思 ⇒ 直接给如实的那一句。
    final body = (q == null || unsupported)
        ? null
        : AudioPagedBody<AudioRadioDto>(
            kind: null,
            state: ref.watch(audioRadioListProvider(q)),
            emptyTitle: unsupported ? asRadioSearchUnsupported : asRadioSearchEmpty,
            errorTitle: asRadioLoadFailed,
            onLoad: () =>
                ref.read(audioRadioListProvider(q).notifier).load(),
            onLoadMore: () =>
                ref.read(audioRadioListProvider(q).notifier).loadMore(),
            onRefresh: () =>
                ref.read(audioRadioListProvider(q).notifier).load(silent: true),
            itemBuilder: (context, radio) => _RadioTile(
              key: Key('as-radio-result-${radio.id}'),
              radio: radio,
              // 搜索结果本来就是电台项（`type:"station"`，有 `url`）；若服务端
              // 真回了容器行，照样不给播放入口（与列表页同一判据）。
              onPlay: radio.isStation ? () => _play(radio) : null,
              onFavorite: radio.hasStreamUrl
                  ? () => addRadioToFavorites(ref, context, radio)
                  : null,
            ),
          );
    return DesignScaffold(
      appBar: AppBar(
        title: TextField(
          key: const Key('as-radio-search-field'),
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: _submit,
          decoration: InputDecoration(
            hintText: asRadioSearchHint,
            border: InputBorder.none,
          ),
        ),
        actions: [
          IconButton(
            key: const Key('as-radio-search-go'),
            tooltip: asRadioSearchTitle,
            icon: const Icon(Icons.search),
            onPressed: () => _submit(_controller.text),
          ),
        ],
      ),
      body: body ??
          AppEmptyState(
            icon: Icons.search,
            title: unsupported ? asRadioSearchUnsupported : asRadioSearchHint,
          ),
    );
  }
}
