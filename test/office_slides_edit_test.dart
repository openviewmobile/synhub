// Office C′ 演示文稿（Slides）批 2 —— 编辑链路（纯逻辑）离线测试。
//
// 覆盖：
//   * 位置算术 **只认 slides schema 的 `isLeaf`**（空 `paragraph` = 容器 = 2；
//     真机 phase 2b 用"没 content 就是叶子"算出 461 → 服务端 411，这是本批的
//     第一处硬证据边界）；
//   * `replace` step 构造形状（与真机帧逐字一致）；
//   * `event` ack 四类解析（`[null,{version}]` / `[{status:402|411|408}]` / 畸形）；
//   * 乐观显示 + 未确认计数；
//   * **402 四步重放**：undo → `poll` 远端增量重放 → redo → 对齐 version 重发；
//   * 重放上限 → 停队首 + **保留输入**；
//   * 411 拒绝 → 回滚 + **点名位置**；
//   * 传输失败 / 畸形 ack → 保留输入；
//   * peer 增量（`poll`/广播）**不覆盖本地未确认**（进 remoteQueue）。
//
// 夹具：`test/fixtures/office_slides_ui2/slides_event_frames.json`
// （真机一次探针的脱敏帧；见 `docs/office-slides-ui-2.md` §①）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_collab/office_collab_client.dart';
import 'package:synhub/src/features/office/office_slides_edit.dart';
import 'package:synhub/src/features/office/office_slides_schema.dart';

Map<String, Object?> _fixture() {
  final raw = File(
    'test/fixtures/office_slides_ui2/slides_event_frames.json',
  ).readAsStringSync();
  return (jsonDecode(raw) as Map).cast<String, Object?>();
}

/// 一个最小但形状真实的 `content.data` 根：
/// `[settings, master_container, slide_container]`；slide 里有
/// `slide_background / slide_content_container(title_slide_holder)/ note`。
Map<String, Object?> _doc({String titleText = ''}) => <String, Object?>{
  'type': 'doc',
  'attrs': <String, Object?>{'schema': 13, 'type': 'presentation'},
  'content': <Object?>[
    <String, Object?>{'type': 'settings'},
    <String, Object?>{'type': 'master_container', 'content': <Object?>[]},
    <String, Object?>{
      'type': 'slide_container',
      'content': <Object?>[
        <String, Object?>{
          'type': 'slide',
          'attrs': <String, Object?>{'id': 'S1'},
          'content': <Object?>[
            <String, Object?>{'type': 'slide_background'},
            <String, Object?>{
              'type': 'slide_content_container',
              'content': <Object?>[
                <String, Object?>{
                  'type': 'title_slide_holder',
                  'content': <Object?>[
                    <String, Object?>{
                      'type': 'title_slide_holder_shape',
                      'content': <Object?>[
                        <String, Object?>{
                          'type': 'title_slide_holder_text_block',
                          'content': <Object?>[
                            <String, Object?>{
                              'type': 'paragraph',
                              if (titleText.isNotEmpty)
                                'content': <Object?>[
                                  <String, Object?>{
                                    'type': 'text',
                                    'text': titleText,
                                  },
                                ],
                            },
                          ],
                        },
                      ],
                    },
                  ],
                },
              ],
            },
            <String, Object?>{'type': 'note', 'content': <Object?>[]},
          ],
        },
      ],
    },
  ],
};

/// 脚本化的假发送通道：逐次消费 `events` / `polls` 队列。
class _FakeSink implements OfficeSlidesCommandSink {
  _FakeSink({List<Object?>? events, List<Object?>? polls})
    : events = events ?? <Object?>[],
      polls = polls ?? <Object?>[];

  final List<Object?> events;
  final List<Object?> polls;
  final List<Map<String, Object?>> sentFrames = <Map<String, Object?>>[];
  final List<int> polledVersions = <int>[];
  final StreamController<OfficeCollabEvent> _in =
      StreamController<OfficeCollabEvent>.broadcast();

  /// 若设置，`sendEvent` 全部抛这个异常（模拟通道断开）。
  Object? throwOnSend;

  /// 置真时 `sendEvent` 挂起，直到 [releaseSend]（用于制造"本地未确认"窗口）。
  bool holdSends = false;
  Completer<Object?>? _held;

  @override
  Future<Object?> sendEvent(Map<String, Object?> frame) async {
    sentFrames.add(frame);
    if (throwOnSend != null) throw throwOnSend!;
    if (holdSends) {
      _held = Completer<Object?>();
      return _held!.future;
    }
    if (events.isEmpty) {
      return <Object?>[
        null,
        <String, Object?>{'version': 99},
      ];
    }
    return events.removeAt(0);
  }

  /// 释放被 [holdSends] 挂起的发送。
  void releaseSend(Object? ack) {
    holdSends = false;
    final held = _held;
    _held = null;
    if (held != null && !held.isCompleted) held.complete(ack);
  }

  @override
  Future<Object?> poll(int version) async {
    polledVersions.add(version);
    if (polls.isEmpty) {
      return <Object?>[
        null,
        <String, Object?>{
          'version': version,
          'wait': true,
          'steps': <Object?>[],
        },
      ];
    }
    return polls.removeAt(0);
  }

  @override
  Stream<OfficeCollabEvent> get incoming => _in.stream;

  void push(OfficeCollabEvent event) => _in.add(event);

  Future<void> close() => _in.close();
}

List<Object?> _okList(int version, [List<Object?>? steps]) => <Object?>[
  null,
  <String, Object?>{
    'version': version,
    'steps': steps ?? <Object?>[],
    'clientIDs': <Object?>['dsh-test'],
  },
];

List<Object?> _err(int status, [String message = 'Error: <probe>.slide']) =>
    <Object?>[
      <String, Object?>{'status': status},
      message,
    ];

void main() {
  group('E1. 位置算术只认 slides schema 的 isLeaf', () {
    test('空 paragraph 是容器（size 2），不是叶子（size 1）', () {
      expect(kOfficeSlidesNodeSpecs['paragraph']!.isLeaf, isFalse);
      expect(officeSlidesNodeSize(<String, Object?>{'type': 'paragraph'}), 2);
      // phase 2b 的 bug：`content.isEmpty => leaf` 会算出 1 → 服务端 411。
      expect(
        officeSlidesNodeSize(<String, Object?>{'type': 'paragraph'}),
        isNot(1),
      );
    });

    test('schema isLeaf 的节点 = 1；text = 长度', () {
      expect(officeSlidesNodeSize(<String, Object?>{'type': 'settings'}), 1);
      expect(
        officeSlidesNodeSize(<String, Object?>{'type': 'text', 'text': 'abcd'}),
        4,
      );
    });

    test('根的子节点从 0 开始；容器的子节点从 start+1 开始', () {
      final doc = _doc(titleText: 'AB');
      // settings(1) master_container(2) → slide_container 从 3 开始。
      expect(officeSlidesNodeStart(doc, <int>[2]), 3);
      // slide_container.content 从 4 开始；slide 在 4。
      expect(officeSlidesNodeStart(doc, <int>[2, 0]), 4);
    });

    test('空文本块 → 内容起点 = nodeStart+1，编辑整块就是插入', () {
      final doc = _doc();
      final blocks = officeSlidesBlocksWithRoot(doc);
      expect(blocks, hasLength(1));
      final b = blocks.single;
      expect(b.slideOrder, 0);
      expect(b.text, '');
      expect(b.editable, isTrue);
      expect(b.length, 0);
      expect(b.contentStart, officeSlidesNodeStart(doc, b.path) + 1);
    });

    test('夹具记录的真机位置（path / node_start / content_start）自洽', () {
      final fix = _fixture();
      final pos =
          (fix['step'] as Map)['position_of_first_slide_paragraph'] as Map;
      expect(pos['node_start'], 564);
      expect(pos['content_start'], 565);
      expect((pos['path'] as List).map((e) => e as int).toList(), <int>[
        2,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
      ]);
    });
  });

  group('E2. step 构造与 ack 解析（真机帧）', () {
    test('replace step 形状逐字一致（插入 / 清空）', () {
      final step = officeSlidesReplaceStep(
        from: 565,
        to: 565,
        text: 'P2SLIDE-TXT',
      );
      expect(step['stepType'], 'replace');
      expect(step['from'], 565);
      expect(step['to'], 565);
      expect(step['slice'], <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': 'P2SLIDE-TXT'},
        ],
        'openLeft': 0,
        'openRight': 0,
      });
      final clear = officeSlidesReplaceStep(from: 1, to: 4, text: '');
      expect(clear['slice'], isNull);
    });

    test('event 帧：version + steps + clientId', () {
      final frame = officeSlidesEventFrame(
        version: 14,
        steps: <Map<String, Object?>>[
          officeSlidesReplaceStep(from: 565, to: 565, text: 'X'),
        ],
        clientId: 'c1',
      );
      expect(frame['version'], 14);
      expect(frame['clientId'], 'c1');
      expect((frame['steps'] as List), hasLength(1));
    });

    test('成功 ack = [null,{version,steps}] → ok + 新版本', () {
      final fix = _fixture();
      final ack = (fix['frames'] as Map)['event_ok_text_replace'] as Map;
      final parsed = officeSlidesAck(ack['s2c']);
      expect(parsed.kind, OfficeSlidesAckKind.ok);
      expect(parsed.version, 15);
      expect(parsed.steps, hasLength(1));
      expect(parsed.steps.single['stepType'], 'replace');
    });

    test('402 / 411 / 408 三态解析 + current 提取', () {
      final p402 = officeSlidesAck(<Object?>[
        <String, Object?>{'status': 402},
        'Error: 1028_<probe>.slide: Not current version. incoming: 113, current: 13',
      ]);
      expect(p402.kind, OfficeSlidesAckKind.versionNotCurrent);
      expect(p402.statusCode, 402);
      expect(officeSlidesParseCurrentVersion(p402.message), 13);

      final p411 = officeSlidesAck(<Object?>[
        <String, Object?>{'status': 411},
        'Error: 1028_<probe>.slide: Invalid command',
      ]);
      expect(p411.kind, OfficeSlidesAckKind.invalidCommand);

      final p408 = officeSlidesAck(<Object?>[
        <String, Object?>{'status': 408},
        <String, Object?>{'status': 408},
      ]);
      expect(p408.kind, OfficeSlidesAckKind.historyNotAvail);
    });

    test('缺 version / 空列表 / 非列表 → 402 或 malformed（不丢输入）', () {
      final missing = officeSlidesAck(<Object?>[
        <String, Object?>{'status': 402},
        'incoming: undefined, current: 14',
      ]);
      expect(missing.kind, OfficeSlidesAckKind.versionNotCurrent);
      expect(officeSlidesAck(<Object?>[]).kind, OfficeSlidesAckKind.malformed);
      expect(officeSlidesAck('nope').kind, OfficeSlidesAckKind.malformed);
    });

    test('poll 增量 ack = [null,{version,wait,steps,clientIDs}]', () {
      final fix = _fixture();
      final frame = (fix['frames'] as Map)['poll_increment_peer'] as Map;
      final parsed = officeSlidesAck(frame['s2c']);
      expect(parsed.kind, OfficeSlidesAckKind.ok);
      expect(parsed.version, 17);
      expect(parsed.clientIds, <String>['dsh-peer']);
      expect(parsed.steps.single['stepType'], 'replace');
    });
  });

  group('E3. 乐观显示 + ack 三态 + 402 四步重放', () {
    test('editBlockText 乐观显示立刻生效，成功后未确认归零', () async {
      final sink = _FakeSink(events: <Object?>[_okList(15)]);
      final edit = OfficeSlidesEditController(
        sink: sink,
        base: _doc(),
        initialVersion: 14,
      );
      edit.editable = true;
      final id = edit.blocks.single.id;
      final start = edit.blocks.single.contentStart;
      await edit.editBlockText(id, 'HELLO');
      await Future<void>.delayed(Duration.zero);
      expect(edit.confirmedCount, 1);
      expect(edit.pendingCount, 0);
      expect(edit.optimisticText(id), 'HELLO');
      expect(edit.version, 15);
      final frame = sink.sentFrames.single;
      expect(frame['version'], 14, reason: 'doc 风格：version = 服务端当前值');
      final steps = frame['steps'] as List;
      final step = steps.single as Map;
      expect(step['from'], start, reason: '就是该块的内容起点');
      expect(step['to'], start, reason: '空块编辑 = 在此插入');
      // 本地 base 也被提交（块文本变 HELLO）。
      expect(edit.blocksForSlide(0).single.text, 'HELLO');
      edit.dispose();
      await sink.close();
    });

    test('402 → 四步重放：undo → poll 远端 → redo → 对齐 version 重发', () async {
      final sink = _FakeSink(
        events: <Object?>[_err(402, 'incoming: 14, current: 14'), _okList(16)],
        polls: <Object?>[
          <Object?>[
            null,
            <String, Object?>{
              'version': 15,
              'wait': true,
              'steps': <Object?>[
                <String, Object?>{
                  'stepType': 'replace',
                  'from': 0,
                  'to': 0,
                  'slice': <String, Object?>{
                    'content': <Object?>[
                      <String, Object?>{'type': 'text', 'text': 'R'},
                    ],
                    'openLeft': 0,
                    'openRight': 0,
                  },
                },
              ],
            },
          ],
        ],
      );
      final edit = OfficeSlidesEditController(
        sink: sink,
        base: _doc(),
        initialVersion: 14,
      );
      edit.editable = true;
      await edit.editBlockText(edit.blocks.single.id, 'MINE');
      await Future<void>.delayed(Duration.zero);

      expect(edit.undoCount, 1, reason: '第一步 undo');
      expect(edit.staleReplays, 1);
      expect(sink.polledVersions, <int>[14], reason: '第二步 poll');
      expect(edit.pendingCount, 0);
      expect(edit.confirmedCount, 1);
      expect(edit.version, 16);
      expect(sink.sentFrames, hasLength(2));
      expect(sink.sentFrames[0]['version'], 14);
      expect(
        sink.sentFrames[1]['version'],
        15,
        reason: '第四步：对齐 poll 回来的 version 再重发',
      );
      edit.dispose();
      await sink.close();
    });

    test('402 超过上限 → 停队首 + **保留输入** + staleBlocked 点名', () async {
      final sink = _FakeSink(
        events: <Object?>[_err(402), _err(402), _err(402), _err(402)],
        polls: <Object?>[
          for (var i = 0; i < 4; i++)
            <Object?>[
              null,
              <String, Object?>{
                'version': 14 + i,
                'wait': true,
                'steps': <Object?>[],
              },
            ],
        ],
      );
      final edit = OfficeSlidesEditController(
        sink: sink,
        base: _doc(),
        initialVersion: 14,
      );
      edit.editable = true;
      await edit.editBlockText(edit.blocks.single.id, 'KEEP');
      await Future<void>.delayed(Duration.zero);

      expect(edit.pendingCount, 1, reason: '绝不丢弃用户输入');
      expect(edit.sendError, isNotNull);
      expect(edit.failures.last.kind, OfficeSlidesEditFailureKind.staleBlocked);
      expect(edit.failures.last.text, 'KEEP');
      expect(edit.failures.last.blockId, isNotNull);
      edit.dispose();
      await sink.close();
    });

    test('411 → 回滚乐观显示 + 点名位置 + 出队', () async {
      final sink = _FakeSink(events: <Object?>[_err(411)]);
      final edit = OfficeSlidesEditController(
        sink: sink,
        base: _doc(),
        initialVersion: 14,
      );
      edit.editable = true;
      final id = edit.blocks.single.id;
      await edit.editBlockText(id, 'BAD');
      await Future<void>.delayed(Duration.zero);
      expect(edit.pendingCount, 0, reason: '明确拒绝才出队');
      expect(edit.optimisticText(id), '', reason: '回滚到 base');
      expect(edit.failures.single.kind, OfficeSlidesEditFailureKind.rejected);
      expect(edit.failures.single.text, 'BAD');
      expect(edit.failures.single.label, contains(id));
      edit.dispose();
      await sink.close();
    });

    test('传输异常 / 畸形 ack → 命令回队首（结果未知，不丢输入）', () async {
      final sink = _FakeSink();
      sink.throwOnSend = StateError('socket gone');
      final edit = OfficeSlidesEditController(
        sink: sink,
        base: _doc(),
        initialVersion: 14,
      );
      edit.editable = true;
      await edit.editBlockText(edit.blocks.single.id, 'RETRY');
      await Future<void>.delayed(Duration.zero);
      expect(edit.pendingCount, 1);
      expect(edit.sendError, isNotNull);
      expect(edit.failures.single.kind, OfficeSlidesEditFailureKind.transport);

      // 修好通道后显式重试 → 成功。
      sink.throwOnSend = null;
      sink.events.add(_okList(15));
      await edit.retryPending();
      await Future<void>.delayed(Duration.zero);
      expect(edit.pendingCount, 0);
      expect(edit.confirmedCount, 1);
      edit.dispose();
      await sink.close();
    });

    test('可编辑门控：editable=false 时 editBlockText 不动', () async {
      final sink = _FakeSink(events: <Object?>[_okList(15)]);
      final edit = OfficeSlidesEditController(
        sink: sink,
        base: _doc(),
        initialVersion: 14,
      );
      expect(edit.canEdit, isFalse);
      await edit.editBlockText(edit.blocks.single.id, 'X');
      expect(sink.sentFrames, isEmpty);
      expect(edit.pendingCount, 0);
      edit.dispose();
      await sink.close();
    });
  });

  group('E4. peer 增量不覆盖本地未确认', () {
    test('本地有未确认时 poll 远端 → 进 remoteQueue，显示仍是本地乐观值', () async {
      final sink = _FakeSink(
        events: <Object?>[_okList(15)],
        polls: <Object?>[
          <Object?>[
            null,
            <String, Object?>{
              'version': 15,
              'wait': true,
              'steps': <Object?>[
                <String, Object?>{
                  'stepType': 'replace',
                  'from': 565,
                  'to': 565,
                  'slice': <String, Object?>{
                    'content': <Object?>[
                      <String, Object?>{'type': 'text', 'text': 'PEER'},
                    ],
                    'openLeft': 0,
                    'openRight': 0,
                  },
                },
              ],
            },
          ],
        ],
      );
      final edit = OfficeSlidesEditController(
        sink: sink,
        base: _doc(titleText: 'BASE'),
        initialVersion: 14,
      );
      edit.editable = true;
      // 让本地发送挂起 → `_inFlight` 保持，制造"本地未确认"窗口。
      sink.holdSends = true;
      final id = edit.blocks.single.id;
      final future = edit.editBlockText(id, 'LOCAL');
      await Future<void>.delayed(Duration.zero);
      // 立刻 poll（此时 in-flight 还在）。
      await edit.pollRemote();
      expect(edit.remoteQueueLength, 1, reason: '暂缓，不应用');
      expect(edit.optimisticText(id), 'LOCAL', reason: '不被 peer 覆盖');
      sink.releaseSend(_okList(15));
      await future;
      await Future<void>.delayed(Duration.zero);
      edit.dispose();
      await sink.close();
    });

    test('本地空闲时 poll 远端 → 直接应用到 base', () async {
      final sink = _FakeSink();
      final edit = OfficeSlidesEditController(
        sink: sink,
        base: _doc(titleText: 'BASE'),
        initialVersion: 14,
      );
      edit.editable = true;
      final pos = edit.blocks.single.contentStart;
      sink.polls.add(<Object?>[
        null,
        <String, Object?>{
          'version': 20,
          'wait': true,
          'steps': <Object?>[
            <String, Object?>{
              'stepType': 'replace',
              'from': pos,
              'to': pos,
              'slice': <String, Object?>{
                'content': <Object?>[
                  <String, Object?>{'type': 'text', 'text': 'PEER'},
                ],
                'openLeft': 0,
                'openRight': 0,
              },
            },
          ],
        },
      ]);
      await edit.pollRemote();
      expect(edit.version, 20);
      expect(edit.blocks.single.text, contains('PEER'));
      edit.dispose();
      await sink.close();
    });

    test('广播 event 带 steps → 与 poll 同规则（本地未确认则暂缓）', () async {
      final sink = _FakeSink();
      final edit = OfficeSlidesEditController(
        sink: sink,
        base: _doc(),
        initialVersion: 14,
      );
      edit.editable = true;
      final pos = edit.blocks.single.contentStart;
      sink.push(
        OfficeCollabEvent('broadcast', <Object?>[
          <String, Object?>{
            'version': 15,
            'steps': <Object?>[
              <String, Object?>{
                'stepType': 'replace',
                'from': pos,
                'to': pos,
                'slice': <String, Object?>{
                  'content': <Object?>[
                    <String, Object?>{'type': 'text', 'text': 'B'},
                  ],
                  'openLeft': 0,
                  'openRight': 0,
                },
              },
            ],
          },
        ]),
      );
      await Future<void>.delayed(Duration.zero);
      expect(edit.blocks.single.text, 'B');
      edit.dispose();
      await sink.close();
    });
  });

  group('E5. 本地 step 应用', () {
    test('replace 在块内按字符区间替换并保留其它文本', () {
      final doc = _doc(titleText: 'ABCDE');
      final block = officeSlidesBlocksWithRoot(doc).single;
      final step = officeSlidesReplaceStep(
        from: block.contentStart + 1,
        to: block.contentStart + 3,
        text: 'xy',
      );
      final next = officeSlidesApplyStep(doc, step);
      expect(next, isNotNull);
      expect(officeSlidesBlocksWithRoot(next!).single.text, 'AxyDE');
    });

    test('不认识 stepType → null（调用方必须登记）', () {
      expect(
        officeSlidesApplyStep(_doc(), <String, Object?>{
          'stepType': 'definitelyNotAStep',
        }),
        isNull,
      );
    });

    test('setRootNodeAttrs 合并根 attrs', () {
      final next = officeSlidesApplyStep(_doc(), <String, Object?>{
        'stepType': 'setRootNodeAttrs',
        'attrs': <String, Object?>{'cx': 960},
      });
      expect((next!['attrs'] as Map)['cx'], 960);
    });
  });
}
