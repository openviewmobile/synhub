// 估算档的**取舍规则**：只归属"已知活动会话"的差分，不可信就丢弃。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/net/device_traffic.dart';
import 'package:synhub/src/core/net/traffic_meter.dart';

import 'support/traffic_test_support.dart';

DeviceTrafficSnapshot _snap({
  required int rx,
  required int tx,
  int mRx = 0,
  int mTx = 0,
  DateTime? at,
}) => DeviceTrafficSnapshot(
  at: at ?? DateTime(2026, 3, 1, 10),
  uidRx: rx,
  uidTx: tx,
  mobileRx: mRx,
  mobileTx: mTx,
  totalRx: 0,
  totalTx: 0,
);

class _QueueProbe implements DeviceTrafficProbe {
  _QueueProbe(this.snaps);
  final List<DeviceTrafficSnapshot?> snaps;
  int calls = 0;
  @override
  Future<DeviceTrafficSnapshot?> snapshot() async {
    final i = calls < snaps.length ? calls : snaps.length - 1;
    calls++;
    return snaps[i];
  }
}

void main() {
  final from = DateTime(2026, 3, 1, 10);

  test('平台不支持 UID 计数 → 丢弃（unsupported）', () {
    final r = attributeUidDelta(
      before: _snap(rx: -1, tx: -1),
      after: _snap(rx: 10, tx: 10),
      from: from,
      to: from.add(const Duration(minutes: 1)),
      minDuration: Duration.zero,
    );
    expect(r.accepted, isFalse);
    expect(r.reason, EstimatedDiscardReason.unsupported);
  });

  test('会话太短 → 丢弃（tooShort）', () {
    final r = attributeUidDelta(
      before: _snap(rx: 0, tx: 0),
      after: _snap(rx: 1 << 20, tx: 0),
      from: from,
      to: from.add(const Duration(milliseconds: 500)),
    );
    expect(r.accepted, isFalse);
    expect(r.reason, EstimatedDiscardReason.tooShort);
  });

  test('差分近零 / 负值 → 丢弃（idle）', () {
    final zero = attributeUidDelta(
      before: _snap(rx: 100, tx: 100),
      after: _snap(rx: 100, tx: 100),
      from: from,
      to: from.add(const Duration(minutes: 5)),
      minDuration: Duration.zero,
    );
    expect(zero.reason, EstimatedDiscardReason.idle);

    final neg = attributeUidDelta(
      before: _snap(rx: 5000, tx: 0),
      after: _snap(rx: 10, tx: 0),
      from: from,
      to: from.add(const Duration(minutes: 5)),
      minDuration: Duration.zero,
    );
    expect(neg.reason, EstimatedDiscardReason.idle);
  });

  test('差分离谱地大（后台 OS 流量混入）→ 丢弃（implausible），不截断', () {
    final r = attributeUidDelta(
      before: _snap(rx: 0, tx: 0),
      after: _snap(rx: kEstimatedSessionCapBytes + 1, tx: 0),
      from: from,
      to: from.add(const Duration(minutes: 5)),
      minDuration: Duration.zero,
    );
    expect(r.accepted, isFalse);
    expect(r.reason, EstimatedDiscardReason.implausible);
    expect(r.totalBytes, 0, reason: '丢弃就是 0，不返回截断值');
  });

  test('可信差分 → 接受，上下行分开', () {
    final r = attributeUidDelta(
      before: _snap(rx: 1000, tx: 500),
      after: _snap(rx: 1000000, tx: 100500),
      from: from,
      to: from.add(const Duration(minutes: 5)),
      minDuration: Duration.zero,
    );
    expect(r.accepted, isTrue);
    expect(r.rxBytes, 999000);
    expect(r.txBytes, 100000);
  });

  test('全局估算器：begin/end 成对 → 写入估算样本；无 probe → 不写', () async {
    final sink = RecordingTrafficSink();
    final tracker = EstimatedTrafficTracker(
      probe: _QueueProbe([
        _snap(rx: 100, tx: 50),
        _snap(rx: 5000100, tx: 250050),
      ]),
      sink: sink,
      minDuration: Duration.zero,
    );
    await tracker.begin(TrafficModules.media);
    expect(tracker.active, isTrue);
    final r = await tracker.end();
    expect(r?.accepted, isTrue);
    expect(tracker.active, isFalse);
    expect(sink.estimates.length, 2);
    expect(sink.estimates.first.module, TrafficModules.media);
    expect(sink.estimates.first.direction, TrafficDirection.down);
    expect(sink.estimates.first.bytes, 5000000);
    expect(sink.estimates.last.direction, TrafficDirection.up);
    expect(sink.estimates.last.bytes, 250000);
  });

  test('空闲期不归属：没有 begin 就 end → 什么都不写', () async {
    final sink = RecordingTrafficSink();
    final tracker = EstimatedTrafficTracker(
      probe: _QueueProbe([_snap(rx: 0, tx: 0)]),
      sink: sink,
      minDuration: Duration.zero,
    );
    expect(await tracker.end(), isNull);
    expect(sink.estimates, isEmpty);
  });

  test('平台不支持时 begin/end 不写样本', () async {
    final sink = RecordingTrafficSink();
    final tracker = EstimatedTrafficTracker(
      probe: _QueueProbe([
        _snap(rx: -1, tx: -1),
        _snap(rx: -1, tx: -1),
      ]),
      sink: sink,
      minDuration: Duration.zero,
    );
    await tracker.begin(TrafficModules.audio);
    final r = await tracker.end();
    expect(r?.reason, EstimatedDiscardReason.unsupported);
    expect(sink.estimates, isEmpty);
  });

  test('快照可序列化往返（基线持久化用）', () {
    final s = _snap(rx: 11, tx: 22, mRx: 1, mTx: 2);
    final back = DeviceTrafficSnapshot.fromJson(s.toJson());
    expect(back, isNotNull);
    expect(back!.uidRx, 11);
    expect(back.uidTx, 22);
    expect(back.mobileRx, 1);
    expect(back.supported, isTrue);
    // supported 为假时如实保留 -1
    final bad = DeviceTrafficSnapshot.fromJson(
      _snap(rx: -1, tx: -1).toJson(),
    );
    expect(bad!.supported, isFalse);
  });
}
