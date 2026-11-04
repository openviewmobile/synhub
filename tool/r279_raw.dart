import 'dart:convert';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';
void main(List<String> a) async {
  final vm = await vmServiceConnectUri(a[0]);
  final info = await vm.getVM();
  final iso = info.isolates!.firstWhere((i) => i.name == 'main');
  final libs = await vm.getIsolate(iso.id!);
  final lib = libs.libraries!.firstWhere((l) => (l.uri ?? '').endsWith('r279_macos_harness.dart'));
  if (a.length > 1) {
    final r = await vm.evaluate(iso.id!, lib.id!, 'r279(${jsonEncode(a[1])})');
    print('dispatch: ${r is ErrorRef ? r.message : r}');
    await Future<void>.delayed(const Duration(seconds: 3));
  }
  final raw = await vm.evaluate(iso.id!, lib.id!, 'r279Last');
  print('RAW r279Last = ${(raw as InstanceRef).valueAsString}');
  await vm.dispose();
}
