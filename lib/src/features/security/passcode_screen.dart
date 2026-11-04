// Phase 9：应用锁的界面 —— 锁屏（4 位数字键盘）与设置页入口。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/security/biometric_auth.dart';
import '../../core/security/passcode_service.dart';

/// 锁屏覆盖层：`locked` 为真时盖住整个 App
class PasscodeGate extends ConsumerWidget {
  const PasscodeGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locked = ref.watch(passcodeLockProvider);
    return Stack(children: [child, if (locked) const PasscodeLockScreen()]);
  }
}

/// 锁屏本体
class PasscodeLockScreen extends ConsumerStatefulWidget {
  const PasscodeLockScreen({super.key});

  @override
  ConsumerState<PasscodeLockScreen> createState() => _PasscodeLockScreenState();
}

class _PasscodeLockScreenState extends ConsumerState<PasscodeLockScreen> {
  String _entered = '';
  String? _error;
  bool _busy = false;

  /// 生物识别入口（可用才显示）。`_bioTried` 保证只自动弹一次
  bool _bioAvailable = false;
  BiometricKind _bioKind = BiometricKind.none;
  bool _bioTried = false;

  /// 生物识别类型标签（界面按语言取；`BiometricKind.label` 只是中文回落）
  String _bioLabelIn(AppText t) => switch (_bioKind) {
    BiometricKind.face => t.passcodeFace,
    BiometricKind.fingerprint => t.passcodeFingerprint,
    BiometricKind.other => t.passcodeBiometric,
    BiometricKind.none => t.passcodeBiometric,
  };

  @override
  void initState() {
    super.initState();
    // 首帧后再查/弹，避免在 build 里碰平台通道
    WidgetsBinding.instance.addPostFrameCallback((_) => _setupBiometric());
  }

  Future<void> _setupBiometric() async {
    final svc = ref.read(passcodeServiceProvider);
    final auth = ref.read(biometricAuthenticatorProvider);
    final ok = await svc.biometricCanUnlock(auth);
    if (!mounted) return;
    setState(() {
      _bioAvailable = ok;
      if (ok) {
        // 标签在下面异步补，不阻塞显示
      }
    });
    if (!ok) return;
    final kind = await auth.kind();
    if (mounted && kind != BiometricKind.none) {
      setState(() => _bioKind = kind);
    }
    // 原版是进来就弹（`BiometricHelper.tryToStartAuthenticate`）
    await _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    if (_busy || _bioTried) return;
    _bioTried = true;
    final svc = ref.read(passcodeServiceProvider);
    final auth = ref.read(biometricAuthenticatorProvider);
    setState(() => _busy = true);
    final ok = await svc.unlockWithBiometric(auth);
    if (!mounted) return;
    if (ok) {
      ref.read(passcodeLockProvider.notifier).markBiometricUnlocked();
    }
    setState(() {
      _busy = false;
      _entered = '';
      if (!ok) _error = context.t.passcodeBiometricFailed;
    });
  }

  void _push(String d) {
    if (_busy || _entered.length >= kPasscodeLength) return;
    setState(() {
      _entered += d;
      _error = null;
    });
    if (_entered.length == kPasscodeLength) _submit();
  }

  void _back() {
    if (_busy || _entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    final ok = await ref.read(passcodeServiceProvider).unlock(_entered);
    if (!mounted) return;
    if (ok) {
      ref.read(passcodeLockProvider.notifier).markUnlocked();
      setState(() {
        _busy = false;
        _entered = '';
        _error = null;
      });
    } else {
      setState(() {
        _busy = false;
        _entered = '';
        _error = context.t.passcodeWrong;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            Icon(
              Icons.lock_outline,
              size: 44,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(context.t.passcodeLocked, style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              context.t.passcodeEnterDigits(kPasscodeLength),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < kPasscodeLength; i++)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < _entered.length
                          ? theme.colorScheme.primary
                          : theme.colorScheme.surfaceContainerHighest,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 24,
              child: _error == null
                  ? null
                  : Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
            ),
            if (_bioAvailable)
              TextButton.icon(
                onPressed: _busy ? null : _tryBiometric,
                icon: Icon(
                  _bioKind == BiometricKind.face
                      ? Icons.face_outlined
                      : Icons.fingerprint,
                ),
                label: Text(
                  context.t.passcodeUnlockWith(_bioLabelIn(context.t)),
                ),
              ),
            const Spacer(),
            _Keypad(onDigit: _push, onBackspace: _back),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({required this.onDigit, required this.onBackspace});

  final void Function(String) onDigit;
  final VoidCallback onBackspace;

  @override
  Widget build(BuildContext context) {
    Widget key(String label, {VoidCallback? onTap, Widget? child}) => SizedBox(
      width: 76,
      height: 60,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: TextButton(
          onPressed: onTap,
          child: child ?? Text(label, style: const TextStyle(fontSize: 22)),
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [for (final d in row) key(d, onTap: () => onDigit(d))],
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(width: 76, height: 60),
            key('0', onTap: () => onDigit('0')),
            key(
              '',
              onTap: onBackspace,
              child: const Icon(Icons.backspace_outlined),
            ),
          ],
        ),
      ],
    );
  }
}
