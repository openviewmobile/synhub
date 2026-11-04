// 测试用的假原生通知层：记录 show/cancel 调用，不碰平台通道。
import 'package:synhub/src/native/background_service.dart';

class FakeBackground extends BackgroundService {
  FakeBackground();

  final List<MessageNotification> shown = <MessageNotification>[];
  final List<int> cancelled = <int>[];
  final List<int> cancelledChannels = <int>[];
  bool started = false;
  bool running = false;
  bool autoBoot = false;
  int permissionRequests = 0;

  @override
  void setActionHandler(void Function(NotificationAction action) handler) {}

  @override
  Future<bool> start({String? title, String? text}) async {
    started = true;
    running = true;
    return true;
  }

  @override
  Future<bool> stop() async {
    running = false;
    return true;
  }

  @override
  Future<bool> isRunning() async => running;

  @override
  Future<bool> show(MessageNotification notification) async {
    shown.add(notification);
    return true;
  }

  @override
  Future<bool> cancel(int postId) async {
    cancelled.add(postId);
    return true;
  }

  @override
  Future<bool> cancelChannel(int channelId) async {
    cancelledChannels.add(channelId);
    return true;
  }

  @override
  Future<bool> cancelTag(int channelId, {int threadId = 0}) async {
    cancelledChannels.add(channelId);
    return true;
  }

  @override
  Future<bool> cancelAll() async => true;

  @override
  Future<int> activeCount() async => shown.length;

  @override
  Future<bool> requestNotificationPermission() async {
    permissionRequests++;
    return true;
  }

  @override
  Future<bool> setAutostart({
    required bool boot,
    bool foreground = false,
  }) async {
    autoBoot = boot;
    return true;
  }

  @override
  Future<({bool boot, bool foreground})> getAutostart() async =>
      (boot: autoBoot, foreground: false);
}
