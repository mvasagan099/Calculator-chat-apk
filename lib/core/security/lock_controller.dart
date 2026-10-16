import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'pin_vault.dart';
import 'pin_performance.dart';

class LockController extends ChangeNotifier with WidgetsBindingObserver {
  LockController(this.vault) {
    WidgetsBinding.instance.addObserver(this);
  }
  final PinVault vault;
  bool unlocked = false;
  bool hasPin = false;
  bool authenticating = false;
  bool relockOnBackground = true;
  bool biometricsEnabled = false;
  Duration timeout = const Duration(minutes: 2);
  DateTime? _backgroundAt;
  Timer? _timer;
  int _epoch = 0;
  bool _disposed = false, _foreground = true, _biometricPrompt = false;
  bool _projectionPrompt = false;
  Future<bool> projectionConsent(Future<bool> Function() request) async {
    if (_disposed || !unlocked || !_foreground || _projectionPrompt) {
      return false;
    }
    final epoch = _epoch;
    _projectionPrompt = true;
    try {
      final granted = await request();
      return granted &&
          !_disposed &&
          unlocked &&
          _foreground &&
          epoch == _epoch;
    } finally {
      _projectionPrompt = false;
    }
  }

  static const _channel = MethodChannel('calculator_messenger/privacy');
  Future<void> initialize() async {
    hasPin = await vault.configured;
    if (!_disposed) notifyListeners();
  }

  Future<bool> unlock(String pin, {PinTrace? trace}) async {
    if (_disposed || !hasPin || authenticating) return false;
    final epoch = _epoch;
    authenticating = true;
    try {
      if (!await vault.verify(pin, trace: trace) ||
          _disposed ||
          !_foreground ||
          epoch != _epoch) {
        return false;
      }
      _open();
      return true;
    } finally {
      authenticating = false;
    }
  }

  Future<bool> biometricUnlock() async {
    if (_disposed || !hasPin || !biometricsEnabled || authenticating) {
      return false;
    }
    final epoch = _epoch;
    authenticating = true;
    _biometricPrompt = true;
    try {
      final valid = await LocalAuthentication().authenticate(
        localizedReason: 'Unlock private space',
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
      if (!valid || _disposed || !_foreground || epoch != _epoch) return false;
      _open();
      return true;
    } on LocalAuthException {
      return false;
    } on PlatformException {
      return false;
    } finally {
      authenticating = false;
      _biometricPrompt = false;
    }
  }

  void _open() {
    unlocked = true;
    touch();
    notifyListeners();
  }

  void lock() {
    ++_epoch;
    if (_disposed) return;
    unlocked = false;
    _timer?.cancel();
    notifyListeners();
  }

  // Cancels a disposed calculator's in-flight result without notifying widgets
  // during route teardown. Existing foreground/background guards still apply.
  void cancelPendingUnlock() => ++_epoch;

  void touch() {
    _timer?.cancel();
    if (unlocked && timeout > Duration.zero) _timer = Timer(timeout, lock);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _foreground = false;
      _backgroundAt ??= DateTime.now();
      // Invalidate pending PIN/biometric results even when the background policy
      // retains an already-open session. A late result must not open a new one.
      ++_epoch;
      if (relockOnBackground) lock();
    } else if (state == AppLifecycleState.inactive) {
      _backgroundAt ??= DateTime.now();
      // Android biometric prompts can transiently make the activity inactive.
      if (relockOnBackground && !_biometricPrompt && !_projectionPrompt) lock();
    } else if (state == AppLifecycleState.resumed) {
      _foreground = true;
      if (_backgroundAt != null &&
          timeout > Duration.zero &&
          DateTime.now().difference(_backgroundAt!) >= timeout) {
        lock();
      }
      _backgroundAt = null;
    }
  }

  Future<void> secureWindow() async {
    try {
      await _channel.invokeMethod<void>('secure');
    } on MissingPluginException {
      /* Desktop/widget tests have no Android window. */
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
