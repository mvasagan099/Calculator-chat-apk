import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'pin_vault.dart';
import 'pin_performance.dart';
import 'media_picker_platform.dart';

abstract interface class BiometricAuthenticator {
  Future<bool> authenticate();
  Future<void> cancel();
}

class SystemBiometricAuthenticator implements BiometricAuthenticator {
  final _authentication = LocalAuthentication();

  @override
  Future<bool> authenticate() => _authentication.authenticate(
    localizedReason: 'Verify your identity',
    biometricOnly: true,
    persistAcrossBackgrounding: false,
  );

  @override
  Future<void> cancel() async {
    await _authentication.stopAuthentication();
  }
}

class LockController extends ChangeNotifier with WidgetsBindingObserver {
  LockController(this.vault, {BiometricAuthenticator? biometrics, MediaPickerPlatform? mediaPicker})
      : _biometrics = biometrics ?? SystemBiometricAuthenticator(),
        _mediaPicker = mediaPicker ?? AndroidMediaPickerPlatform() {
    _mediaPicker.onInvalidated = (token) {
      if (_pickerToken == token) lock();
    };
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'quickLock') {
        quickLock();
      }
    });
    WidgetsBinding.instance.addObserver(this);
  }
  final PinVault vault;
  final BiometricAuthenticator _biometrics;
  final MediaPickerPlatform _mediaPicker;
  VoidCallback? onRelock;
  String? _pickerToken;
  bool _pickerArmed = false;
  Completer<void>? _pickerResumed;
  bool get mediaPickerActive => _pickerToken != null;
  int get securityEpoch => _epoch;
  bool privateActionValid(int epoch) => !_disposed && unlocked && hasPin &&
      _foreground && !mediaPickerActive && epoch == _epoch;

  /// A bounded handoff, never an unlock. The unlocked capability is retained
  /// behind a mask only for the exact native launch/result and same session.
  Future<T?> pickMedia<T>(String kind, Future<T?> Function() request, {
    required bool Function() authorized,
    required Future<bool> Function() reauthorize,
  }) async {
    if (!privateActionValid(_epoch) || authenticating || !authorized()) {
      throw StateError('Unlock an approved session before selecting media');
    }
    final epoch = _epoch;
    final token = '${DateTime.now().microsecondsSinceEpoch}:$epoch';
    _pickerToken = token;
    final resumed = Completer<void>();
    _pickerResumed = resumed;
    final deadline = Timer(const Duration(minutes: 2), () {
      if (_pickerToken == token && epoch == _epoch) lock();
    });
    var returnVerified = false;
    notifyListeners();
    try {
      // Paint the privacy cover before Android's window transition/snapshot.
      await WidgetsBinding.instance.endOfFrame;
      if (_disposed || epoch != _epoch) return null;
      if (!authorized()) { lock(); return null; }
      final armed = await _mediaPicker.arm(token, kind);
      if (_disposed || epoch != _epoch) return null;
      _pickerArmed = armed;
      if (!armed || !authorized()) {
        lock();
        return null;
      }
      T? selected;
      Object? failure;
      StackTrace? failureStack;
      try { selected = await request(); }
      catch (error, stack) { failure = error; failureStack = stack; }
      if (_disposed || epoch != _epoch) return null;
      if (!authorized()) { lock(); return null; }
      final returned = await _mediaPicker.finish(token);
      if (_disposed || epoch != _epoch) return null;
      if (!returned) {
        lock();
        return null;
      }
      // Native has consumed its result. Stop the lifecycle exception now,
      // including while the subsequent device recheck/cancel is awaiting I/O.
      _pickerArmed = false;
      if (!_foreground) {
        await resumed.future.timeout(const Duration(seconds: 3));
      }
      if (_disposed || epoch != _epoch) return null;
      if (!_foreground || !authorized()) { lock(); return null; }
      final approved = await reauthorize();
      if (_disposed || epoch != _epoch) return null;
      if (!approved || !_foreground || !authorized()) {
        lock();
        return null;
      }
      returnVerified = true;
      if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
      return selected;
    } on PlatformException {
      if (returnVerified) rethrow;
      if (epoch == _epoch) lock();
      return null;
    } on MissingPluginException {
      if (returnVerified) rethrow;
      if (epoch == _epoch) lock();
      return null;
    } on TimeoutException {
      if (epoch == _epoch) lock();
      return null;
    } catch (_) {
      if (!returnVerified && epoch == _epoch) lock();
      rethrow;
    } finally {
      deadline.cancel();
      try { await _mediaPicker.cancel(token); } catch (_) { /* Already invalid. */ }
      if (_pickerToken == token) {
        _pickerToken = null;
        _pickerArmed = false;
        _pickerResumed = null;
      }
      if (!_disposed) notifyListeners();
    }
  }
  bool unlocked = false;
  bool hasPin = false;
  bool authenticating = false;
  bool relockOnBackground = true;
  bool _biometricsEnabled = false;
  bool get biometricsEnabled => _biometricsEnabled;
  set biometricsEnabled(bool value) {
    if (_biometricsEnabled == value) return;
    _biometricsEnabled = value;
    cancelPendingUnlock();
  }
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
    if (_disposed || !_foreground || mediaPickerActive || !hasPin || authenticating) return false;
    final epoch = _epoch;
    authenticating = true;
    try {
      if (!await vault.verify(pin, trace: trace) ||
          _disposed ||
          !_foreground ||
          epoch != _epoch) {
        return false;
      }
      // PIN proof stays local to this attempt. Never publish an unlocked state
      // until the optional second factor succeeds in the same foreground epoch.
      if (biometricsEnabled) {
        _biometricPrompt = true;
        if (!await _biometrics.authenticate()) return false;
      }
      if (_disposed || !_foreground || epoch != _epoch) return false;
      _open();
      return true;
    } on LocalAuthException {
      return false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
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
    cancelPendingUnlock();
    final token = _pickerToken;
    if (token != null) unawaited(_mediaPicker.cancel(token).catchError((Object _) {}));
    _pickerToken = null;
    _pickerArmed = false;
    if (_pickerResumed?.isCompleted == false) _pickerResumed!.complete();
    _pickerResumed = null;
    if (_disposed) return;
    unlocked = false;
    _timer?.cancel();
    try {
      onRelock?.call();
    } catch (_) {}
    notifyListeners();
  }

  void quickLock() {
    if (unlocked) {
      lock();
    }
  }

  Future<void> setShakeToLock(bool enabled) async {
    // Android-only sensor integration. Flutter widget tests run on the host
    // platform and cannot wait for an Android platform-channel response.
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setShakeToLock', enabled);
    } on MissingPluginException {
      /* Not every Android build exposes this optional integration. */
    } catch (_) {
      // Optional quick-lock setting must never block calculator startup.
    }
  }

  // Cancels a disposed calculator's in-flight result without notifying widgets
  // during route teardown. Existing foreground/background guards still apply.
  void cancelPendingUnlock() {
    ++_epoch;
    if (_biometricPrompt) unawaited(_cancelBiometrics());
  }

  Future<void> _cancelBiometrics() async {
    try {
      await _biometrics.cancel();
    } catch (_) {
      // The epoch is already invalidated, even if the platform cannot cancel.
    }
  }

  void touch() {
    _timer?.cancel();
    if (unlocked && timeout > Duration.zero) _timer = Timer(timeout, lock);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mediaPickerActive && _pickerArmed && state != AppLifecycleState.detached) {
      if (state == AppLifecycleState.resumed) {
        _foreground = true;
        if (_pickerResumed?.isCompleted == false) _pickerResumed!.complete();
      } else {
        _foreground = false;
      }
      // Native return and user-leave signals decide this one handoff. The existing
      // inactivity timer continues running; all other background paths below
      // retain their original lock behavior.
      return;
    }
    if (mediaPickerActive) {
      _foreground = state == AppLifecycleState.resumed;
      if (_foreground) {
        if (_pickerResumed?.isCompleted == false) _pickerResumed!.complete();
        return;
      }
      lock();
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _foreground = false;
      _backgroundAt ??= DateTime.now();
      // Invalidate pending PIN/biometric results even when the background policy
      // retains an already-open session. A late result must not open a new one.
      if (relockOnBackground) {
        lock();
      } else {
        cancelPendingUnlock();
      }
    } else if (state == AppLifecycleState.inactive) {
      _backgroundAt ??= DateTime.now();
      // Android biometric prompts can transiently make the activity inactive.
      if (!_biometricPrompt && !_projectionPrompt) {
        if (relockOnBackground) {
          lock();
        } else {
          cancelPendingUnlock();
        }
      }
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
    final token = _pickerToken;
    if (token != null) unawaited(_mediaPicker.cancel(token).catchError((Object _) {}));
    _mediaPicker.onInvalidated = null;
    cancelPendingUnlock();
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
