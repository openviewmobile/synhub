// 「回到正在播放的那一屏」的**唯一**入口（r653 · `DA257`）。
//
// 为什么要有这个文件：点迷你条、点通知栏的媒体卡，用户心里是**同一个动作** ——
// 「我在听东西，让我看看它」。如果两处各写一份 if/else（电台弹面板 / 歌曲压单曲页），
// 迟早有一处忘了跟着改（r652 的教训：同一个东西两个入口就有两套行为）。
//
// 判据来源：`MediaItem.extras['kind']`（r633 起由 `AudioTrackInfo.kind` 落下来），
// **不用 id 前缀猜** —— 自定义电台的 id 是服务端给的 `radio_<n>`、歌曲是
// `music_<md5>`，两套都不保证；`kind` 缺失时才回落"歌曲"（历史行为）。
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../media/audio_handler.dart';
import 'audio_radio_player_sheet.dart';
import 'audio_song_page.dart';

/// 这条 `MediaItem` 是不是电台（判据只看 `extras['kind']`，供用例与页面共用）。
bool nowPlayingIsRadio(MediaItem item) =>
    AudioTrackKind.fromTag(item.extras?['kind']) == AudioTrackKind.radio;

/// 打开"正在播放"的那一屏。返回是否真的打开了（没有可打开的目标时 `false`）。
///
/// * 电台（直播流）→ 电台播放面板；
/// * 其他（含 `kind` 缺失）→ 单曲页（按当前 `MediaItem` 的歌去取详情）。
///
/// `rootNavigator: true` 是有意的：点通知时用户可能在任意深度的页面上
/// （聊天详情、设置…），播放页要压在**最上层**，而不是插在当前页的局部栈里。
Future<void> openNowPlaying(BuildContext context, {required MediaItem item}) async {
  if (nowPlayingIsRadio(item)) {
    // 同样不 await：弹层的 Future 要等它被关掉才完成
    unawaited(showRadioPlayerSheet(context, item: item));
    return;
  }
  // ★ 不 await push 的完成：它的 Future 要等**页面被关掉**才完成。
  //   调用方（通知栏回调 / 迷你条）只关心"开起来了"，等它会把通道回调挂住
  //   （r653 用例当场被这个挂死过一次）。
  unawaited(
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => AudioSongDetailPage(songId: item.id, title: item.title),
      ),
    ),
  );
}
