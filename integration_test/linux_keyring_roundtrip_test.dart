// r701 · B8：**已解锁的 keyring** 下，App 的 `KeystoreSecretKeeper` 是不是真的落到了 libsecret。
//
// 为什么这么判：
//   * `flutter_secure_storage_linux` 把整张键值表**序列化成一个 JSON**，
//     存进**一个** libsecret item：label = `<APPLICATION_ID>/FlutterSecureStorage`，
//     attribute `account = <APPLICATION_ID>.secureStorage`（见插件 `register_with_registrar`）；
//   * 所以"App 说存上了"不等于"keyring 里有"——必须在**另一个进程**里读：
//     `secret-tool search --all account com.openviewai.synhub.secureStorage`；
//   * 进程内 `seal → open` 只能证明插件没抛异常；**两次进程之间** 才能证明"落盘了"。
//
// 判据（两段，各跑一次 app 进程）：
//   ① `KR_MODE=seal`：`seal()` 返回 `macos-secure:<alias>`（非 null ⇒ 过了起飞前检查）；
//   ② `KR_MODE=open` + `KR_ENC=<上一段返回的串>`：**新进程**里 `open()` 读回同一明文。
//   反向（容器侧）：把 `<HOME>/.local/share/keyrings` 清空 ⇒ `seal()` 必须回 null，
//   且**不许**拉起 gnome-keyring / gcr-prompter（DA338 的纪律：宁可不记，也不冻界面）。
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/core/security/keystore_secret_keeper.dart';

const String _secret = 'r701-roundtrip-secret';
const String _mode = String.fromEnvironment('KR_MODE', defaultValue: 'seal');
const String _enc = String.fromEnvironment('KR_ENC');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('keyring 往返：$_mode', (tester) async {
    final keeper = const KeystoreSecretKeeper();
    // ignore: avoid_print
    print('[kr] supported=${KeystoreSecretKeeper.isSupported} mode=$_mode');
    if (_mode == 'none') {
      // 反向：没有已存在的 keyring 时，起飞前检查必须**在碰插件之前**挡住
      expect(KeystoreSecretKeeper.isSupported, isFalse,
          reason: '没有 keyring 时 isSupported 必须 false（否则就会去碰 libsecret、弹模态框）');
      expect(await keeper.seal(_secret), isNull, reason: '不许假装存上了');
      // ignore: avoid_print
      print('[kr] ok=no-keyring-skip');
      return;
    }
    expect(KeystoreSecretKeeper.isSupported, isTrue,
        reason: 'Linux 的 secureStorage 能力位是 available；false ⇒ 能力门或起飞前检查挡了');

    if (_mode == 'seal') {
      final encoded = await keeper.seal(_secret);
      // ignore: avoid_print
      print('[kr] sealed=$encoded');
      expect(encoded, isNotNull, reason: '有解锁的 keyring 时 seal 必须成功');
      expect(encoded!, startsWith('macos-secure:'));
      // 同一个进程里再读一次，先排除"插件没接线"这一层
      expect(await keeper.open(encoded), _secret);
    } else {
      expect(_enc, isNotEmpty, reason: 'KR_ENC 必须由上一段传进来');
      final value = await keeper.open(_enc);
      // ignore: avoid_print
      print('[kr] opened=$value');
      expect(value, _secret, reason: '新进程里必须能从 keyring 读回同一明文（跨进程 = 真落盘）');
    }
  });
}
