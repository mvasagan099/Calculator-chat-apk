import 'package:flutter/services.dart';

abstract interface class MediaPickerPlatform {
  set onInvalidated(void Function(String token)? callback);
  Future<bool> arm(String token, String kind);
  Future<bool> finish(String token);
  Future<void> cancel(String token);
}

/// Android confirms a matching activity result; Flutter lifecycle alone cannot
/// distinguish a picker from Home/Recents. Missing support fails closed.
class AndroidMediaPickerPlatform implements MediaPickerPlatform {
  AndroidMediaPickerPlatform() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'invalidated' && call.arguments is String) {
        _onInvalidated?.call(call.arguments as String);
      }
    });
  }
  static const _channel = MethodChannel('calculator_messenger/media_picker');
  void Function(String)? _onInvalidated;
  @override
  set onInvalidated(void Function(String)? callback) => _onInvalidated = callback;
  @override
  Future<bool> arm(String token, String kind) async =>
      await _channel.invokeMethod<bool>('arm', {'token': token, 'kind': kind}) == true;
  @override
  Future<bool> finish(String token) async =>
      await _channel.invokeMethod<bool>('finish', {'token': token}) == true;
  @override
  Future<void> cancel(String token) => _channel.invokeMethod<void>('cancel', {'token': token});
}
