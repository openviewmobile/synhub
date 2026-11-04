// 轨道 / 画面比例 / 音量的**纯数据模型**（`media_tracks.dart`）离线测试。
//
// 原生桥把 Media3 `Tracks.Group` 摊平成 `Map` 经 EventChannel 发给 Dart；
// 这里钉死"键名 ↔ 模型"的双向映射（原生改键名只该改一处），以及画面比例的
// 稳定标识（Dart 与原生用同一个字符串）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/media/media_tracks.dart';

void main() {
  group('画面比例模式', () {
    test('code ↔ 枚举', () {
      expect(MediaAspectMode.fit.code, 'fit');
      expect(MediaAspectMode.fill.code, 'fill');
      expect(MediaAspectMode.zoom.code, 'zoom');
      expect(MediaAspectMode.stretch.code, 'stretch');
      for (final mode in MediaAspectMode.values) {
        expect(MediaAspectMode.fromCode(mode.code), mode);
      }
    });

    test('未知/空/null → fit（默认，不做假选项也不抛）', () {
      expect(MediaAspectMode.fromCode('nope'), MediaAspectMode.fit);
      expect(MediaAspectMode.fromCode(''), MediaAspectMode.fit);
      expect(MediaAspectMode.fromCode(null), MediaAspectMode.fit);
    });

    test('四种模式肉眼可分辨：放大倍数是 1.25', () {
      expect(kMediaZoomScale, greaterThan(1.0));
    });
  });

  group('轨道模型 ↔ 原生 Map', () {
    test('fromMap 读全部字段', () {
      final track = MediaTrackInfo.fromMap(const {
        'id': 'audio:1:0',
        'kind': 'audio',
        'label': '国语',
        'language': 'zho',
        'codec': 'mp4a.40.2',
        'channels': 2,
        'default': true,
        'selected': true,
        'group': 1,
        'index': 0,
      });
      expect(track.id, 'audio:1:0');
      expect(track.kind, MediaTrackKind.audio);
      expect(track.label, '国语');
      expect(track.language, 'zho');
      expect(track.codec, 'mp4a.40.2');
      expect(track.channels, 2);
      expect(track.isDefault, isTrue);
      expect(track.isSelected, isTrue);
      expect(track.groupIndex, 1);
      expect(track.trackIndex, 0);
    });

    test('DA267：原生说 `supported:false` ⇒ Dart 侧必须照抄（AC3/EAC3/TrueHD 不许装可解）', () {
      // ★ r655 真机：这段样本（AC3 6ch）在 HONOR 上没有真解码器，
      //   Media3 的 `isTrackSupported()` 给 false；Kotlin 侧还额外要求
      //   `MediaCodecList.findDecoderForFormat()` 真能拿到解码器（DA267：
      //   透传格式曾经被报成"可解"，用户看到的是没后缀的音轨 + 一片静音）。
      //   这里钉的是**交接**：原生给 false，Dart 不许自己翻成 true。
      final unsupported = MediaTrackInfo.fromMap(const {
        'id': 'audio:0:0',
        'kind': 'audio',
        'codec': 'audio/ac3',
        'channels': 6,
        'supported': false,
      });
      expect(unsupported.isSupported, isFalse,
          reason: 'DA267：原生已判定解不了，Dart 不许反悔');

      final missing = MediaTrackInfo.fromMap(const {
        'id': 'audio:0:1',
        'kind': 'audio',
        'codec': 'audio/ac3',
      });
      expect(missing.isSupported, isTrue,
          reason: 'DA267：老桥不送这个键时保持原口径（只有显式 false 才是 false）');
    });

    test('toMap → fromMap 往返一致（原生/Dart 只该改一处）', () {
      const original = MediaTrackInfo(
        id: 'subtitle:2:1',
        kind: MediaTrackKind.subtitle,
        label: '简体',
        language: 'chs',
        codec: 'subrip',
        isDefault: false,
        isSelected: true,
        groupIndex: 2,
        trackIndex: 1,
      );
      final roundTrip = MediaTrackInfo.fromMap(original.toMap());
      expect(roundTrip.id, original.id);
      expect(roundTrip.kind, original.kind);
      expect(roundTrip.label, original.label);
      expect(roundTrip.language, original.language);
      expect(roundTrip.codec, original.codec);
      expect(roundTrip.groupIndex, original.groupIndex);
      expect(roundTrip.trackIndex, original.trackIndex);
      expect(roundTrip.isSelected, isTrue);
    });

    test('缺字段 / 类型不对 → 按默认值，不抛', () {
      final track = MediaTrackInfo.fromMap(const {'channels': '3'});
      expect(track.id, '');
      expect(track.kind, MediaTrackKind.audio);
      expect(track.channels, 3, reason: '字符串数字也认');
      expect(track.isDefault, isFalse);
      expect(track.isSelected, isFalse);
      expect(track.groupIndex, 0);
    });

    test('kind=subtitle 才建成字幕轨', () {
      expect(
        MediaTrackInfo.fromMap(const {'kind': 'subtitle'}).kind,
        MediaTrackKind.subtitle,
      );
      expect(
        MediaTrackInfo.fromMap(const {'kind': 'audio'}).kind,
        MediaTrackKind.audio,
      );
      expect(
        MediaTrackInfo.fromMap(const {'kind': 'video'}).kind,
        MediaTrackKind.audio,
        reason: '视频轨不进选择菜单 → 归到 audio 分支，但原生不会发',
      );
    });

    test('parseTrackList：非 List → 空表；List 里的非 Map 项被跳过', () {
      expect(parseTrackList(null), isEmpty);
      expect(parseTrackList('nope'), isEmpty);
      final list = parseTrackList(const [
        {'id': 'audio:0:0', 'kind': 'audio'},
        'junk',
        {'id': 'subtitle:1:0', 'kind': 'subtitle'},
      ]);
      expect(list, hasLength(2));
      expect(list[1].kind, MediaTrackKind.subtitle);
    });

    test('copyWith 只改选中态（重建 override 时用）', () {
      const track = MediaTrackInfo(id: 'audio:0:1', kind: MediaTrackKind.audio);
      final selected = track.copyWith(isSelected: true);
      expect(selected.isSelected, isTrue);
      expect(selected.id, track.id);
      expect(track.isSelected, isFalse, reason: '原对象不变');
    });
  });

  group('显示兜底（不是 l10n，只是"别空白"）', () {
    test('label > 语言名 > #序号（编码只在 detail 里，DA243）', () {
      expect(
        const MediaTrackInfo(
          id: 'a',
          kind: MediaTrackKind.audio,
          label: '国语',
          language: 'zho',
          codec: 'aac',
        ).displayLabel,
        '国语',
      );
      expect(
        const MediaTrackInfo(
          id: 'a',
          kind: MediaTrackKind.audio,
          language: 'zho',
          codec: 'aac',
        ).displayLabel,
        '中文',
      );
      // ★ r645（DA243）：**编码不再当名字** —— 容器没给标题/语言时给 `#序号`，
      //   编码留在 `detail`（第二行小字）。旧实现在这里返回 `aac`，
      //   真机上漂到界面的就是 `audio/mpeg` 这种 MIME 串。
      expect(
        const MediaTrackInfo(
          id: 'a',
          kind: MediaTrackKind.audio,
          codec: 'aac',
        ).displayLabel,
        '#1',
      );
      expect(
        const MediaTrackInfo(
          id: 'a',
          kind: MediaTrackKind.audio,
          trackIndex: 1,
        ).displayLabel,
        '#2',
      );
    });

    // ★ r645（DA243）：真机「播放设置 → 音轨」右侧印的是 `audio/mpeg`（MIME）。
    //   判据：名字里**不许**出现协议名/编码 id；编码仍在 detail 第二行。
    //   反向验证：把 `_looksLikeMimeOrCodec` 判据去掉（名字档位回到 codec）⇒ 红。
    test('DA243：MIME / 编码 id 不许当音轨名；编码留在 detail', () {
      const mimeLabel = MediaTrackInfo(
        id: 'audio:0:1',
        kind: MediaTrackKind.audio,
        label: 'audio/mpeg',
        codec: 'audio/mpeg',
        trackIndex: 1,
      );
      expect(mimeLabel.displayLabel, '#2');
      expect(mimeLabel.displayLabel.contains('/'), isFalse);
      expect(mimeLabel.detail, 'audio/mpeg');

      const codecLabel = MediaTrackInfo(
        id: 'audio:0:0',
        kind: MediaTrackKind.audio,
        label: 'mp4a.40.2',
        codec: 'mp4a.40.2',
      );
      expect(codecLabel.displayLabel, '#1');

      // 反向：真标题（哪怕带空格/中文/连字符）不许被误判成协议名
      expect(
        const MediaTrackInfo(
          id: 'a',
          kind: MediaTrackKind.audio,
          label: 'Commentary - Director',
          codec: 'aac',
        ).displayLabel,
        'Commentary - Director',
      );
      // 有语言时仍优先语言（比 `#1` 更有信息）
      expect(
        const MediaTrackInfo(
          id: 'a',
          kind: MediaTrackKind.audio,
          label: 'audio/mpeg',
          language: 'zho',
          codec: 'audio/mpeg',
        ).displayLabel,
        '中文',
      );
    });

    test('detail 只有编码/声道（没有就空串）', () {
      expect(
        const MediaTrackInfo(
          id: 'a',
          kind: MediaTrackKind.audio,
          codec: 'aac',
          channels: 6,
        ).detail,
        'aac · 6 ch',
      );
      expect(
        const MediaTrackInfo(id: 'a', kind: MediaTrackKind.audio).detail,
        '',
      );
    });

    test('语言码 → 可读名（认不出原样返回）', () {
      expect(mediaLanguageName('zho'), '中文');
      expect(mediaLanguageName('ZH'), '中文');
      expect(mediaLanguageName('zh-CN'), '中文');
      expect(mediaLanguageName('eng'), 'English');
      expect(mediaLanguageName('fra'), 'Français');
      expect(mediaLanguageName('und'), '未标注');
      expect(mediaLanguageName('xyz'), 'xyz');
    });
  });

  group('选中判定（字幕轨 id=null 表示关闭）', () {
    const tracks = [
      MediaTrackInfo(
        id: 's:0',
        kind: MediaTrackKind.subtitle,
        isSelected: false,
      ),
      MediaTrackInfo(
        id: 's:1',
        kind: MediaTrackKind.subtitle,
        isSelected: true,
      ),
    ];

    test('按 id 找选中的', () {
      expect(isTrackSelected(tracks, 's:1'), isTrue);
      expect(isTrackSelected(tracks, 's:0'), isFalse);
    });

    test('null = 关闭：只有全部未选中才算"已关闭"', () {
      expect(isTrackSelected(tracks, null), isFalse);
      expect(
        isTrackSelected(const [
          MediaTrackInfo(id: 's:0', kind: MediaTrackKind.subtitle),
        ], null),
        isTrue,
      );
    });

    test('空表 + null → 视为已关闭', () {
      expect(isTrackSelected(const [], null), isTrue);
    });
  });

  // ★ r657（DA272）：真机撞到的"行值撒谎" —— 兜底引擎只在 `selectedXxxTrackId`
  //   上说真话，每条轨道的 `isSelected` 一律 false。行值必须按 **id 优先** 取。
  group('DA272 选中项解析（id 优先，isSelected 兜底）', () {
    const subs = [
      MediaTrackInfo(id: 's:0', kind: MediaTrackKind.subtitle, language: 'zho'),
      MediaTrackInfo(id: 's:1', kind: MediaTrackKind.subtitle, language: 'eng'),
    ];

    test('DA272 只有 id 有信息（isSelected 全 false）⇒ 仍要给对的那条', () {
      final picked = selectedMediaTrack(subs, 's:1');
      expect(picked, isNotNull);
      expect(picked!.id, 's:1');
      expect(picked.displayLabel, mediaLanguageName('eng'));
    });

    test('DA272 id 与 isSelected 打架时以 id 为准', () {
      const tracks = [
        MediaTrackInfo(id: 's:0', kind: MediaTrackKind.subtitle, isSelected: true),
        MediaTrackInfo(id: 's:1', kind: MediaTrackKind.subtitle),
      ];
      expect(selectedMediaTrack(tracks, 's:1')!.id, 's:1');
    });

    test('DA272 老引擎只给 isSelected（id 为 null 或不认识）⇒ 退回 isSelected', () {
      const tracks = [
        MediaTrackInfo(id: 's:0', kind: MediaTrackKind.subtitle),
        MediaTrackInfo(id: 's:1', kind: MediaTrackKind.subtitle, isSelected: true),
      ];
      expect(selectedMediaTrack(tracks, null)!.id, 's:1');
      expect(selectedMediaTrack(tracks, 's:9')!.id, 's:1');
    });

    test('DA272 什么都没选 ⇒ null（界面据此印 "Subtitles off"）', () {
      expect(selectedMediaTrack(subs, null), isNull);
      expect(selectedMediaTrack(const [], 's:0'), isNull);
      expect(selectedMediaTrack(subs, ''), isNull);
    });
  });
}
