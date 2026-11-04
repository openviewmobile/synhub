// 一次性收尾：删掉测试账号的头像（恢复到 avatar_version=0）。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main(List<String> args) async {
  final apply = args.contains('--apply');
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_NAS_ACCOUNT']!,
    password: Platform.environment['SYNO_NAS_PASSWORD']!,
    session: 'Chat',
  );
  final chat = ChatApi(api);
  final me = await chat.myUser();
  print('当前 nickname="${me?.nickname}" avatar_version=${me?.avatarVersion}');
  if (!apply) {
    print('（预览模式，加 --apply 才真删）');
    exit(0);
  }
  if ((me?.avatarVersion ?? 0) != 0) {
    await chat.deleteProfilePhoto();
    final after = await chat.myUser();
    print('删除后 avatar_version=${after?.avatarVersion}');
  }
  exit(0);
}
