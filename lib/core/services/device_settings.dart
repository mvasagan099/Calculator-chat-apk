import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../security/lock_controller.dart';

class DeviceSettings extends ChangeNotifier {
  DeviceSettings(this.preferences, this.lock, {this.keyPrefix = ''});
  final String keyPrefix;
  String key(String value) => '$keyPrefix$value';
  final SharedPreferences preferences;
  final LockController lock;
  ThemeMode get theme {
    final index = preferences.getInt(key('theme')) ?? 0;
    return index >= 0 && index < ThemeMode.values.length
        ? ThemeMode.values[index]
        : ThemeMode.system;
  }

  Future<void> initialize() async {
    lock.relockOnBackground =
        preferences.getBool(key('relock.background')) ?? true;
    lock.timeout = Duration(
      seconds: preferences.getInt(key('relock.seconds')) ?? 120,
    );
    lock.biometricsEnabled = preferences.getBool(key('biometrics')) ?? false;
  }

  Future<void> setTheme(ThemeMode theme) async {
    await preferences.setInt(key('theme'), theme.index);
    notifyListeners();
  }

  Future<void> setRelock(bool value) async {
    lock.relockOnBackground = value;
    await preferences.setBool(key('relock.background'), value);
    notifyListeners();
  }

  Future<void> setTimeout(int seconds) async {
    lock.timeout = Duration(seconds: seconds);
    lock.touch();
    await preferences.setInt(key('relock.seconds'), seconds);
    notifyListeners();
  }

  Future<void> setBiometrics(bool value) async {
    lock.biometricsEnabled = value;
    await preferences.setBool(key('biometrics'), value);
    notifyListeners();
  }
}
