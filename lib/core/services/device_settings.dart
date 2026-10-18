import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../security/lock_controller.dart';
import '../theme/app_theme.dart';

enum NotificationPrivacy {
  generic('Generic (hides sender & text)'),
  detailed('Detailed (shows sender name)'),
  silent('Silent (no sound or vibration)');

  const NotificationPrivacy(this.label);
  final String label;
}

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

  ThemeMode get messengerAppearance {
    final name = preferences.getString(key('messenger.appearance'));
    return ThemeMode.values.where((mode) => mode.name == name).firstOrNull ?? theme;
  }
  Future<void> setMessengerAppearance(ThemeMode value) async {
    await preferences.setString(key('messenger.appearance'), value.name);
    notifyListeners();
  }

  MessengerTheme get messengerTheme {
    final name = preferences.getString(key('messenger.theme'));
    return MessengerTheme.values.where((value) => value.name == name).firstOrNull ?? MessengerTheme.defaultTheme;
  }

  Future<void> setMessengerTheme(MessengerTheme value) async {
    await preferences.setString(key('messenger.theme'), value.name);
    notifyListeners();
  }

  bool get amoledMode => preferences.getBool(key('theme.amoled')) ?? false;

  Future<void> setAmoledMode(bool value) async {
    await preferences.setBool(key('theme.amoled'), value);
    notifyListeners();
  }

  NotificationPrivacy get notificationPrivacy {
    final name = preferences.getString(key('notification.privacy'));
    return NotificationPrivacy.values.where((v) => v.name == name).firstOrNull ?? NotificationPrivacy.generic;
  }

  Future<void> setNotificationPrivacy(NotificationPrivacy value) async {
    await preferences.setString(key('notification.privacy'), value.name);
    notifyListeners();
  }

  bool get shakeToLock => preferences.getBool(key('quick_lock.shake')) ?? true;

  Future<void> setShakeToLock(bool value) async {
    await preferences.setBool(key('quick_lock.shake'), value);
    await lock.setShakeToLock(value);
    notifyListeners();
  }

  bool get quickLockShortcut => preferences.getBool(key('quick_lock.shortcut')) ?? true;

  Future<void> setQuickLockShortcut(bool value) async {
    await preferences.setBool(key('quick_lock.shortcut'), value);
    notifyListeners();
  }

  List<String> get customFolders {
    return preferences.getStringList(key('chat_folders.custom')) ?? <String>[];
  }

  Future<void> addCustomFolder(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final folders = customFolders.toList();
    if (!folders.contains(trimmed)) {
      folders.add(trimmed);
      await preferences.setStringList(key('chat_folders.custom'), folders);
      notifyListeners();
    }
  }

  Future<void> removeCustomFolder(String name) async {
    final folders = customFolders.toList();
    if (folders.remove(name)) {
      await preferences.setStringList(key('chat_folders.custom'), folders);
      notifyListeners();
    }
  }

  List<String> getFoldersForChat(String cid) {
    return preferences.getStringList(key('chat_folder_assign.$cid')) ?? <String>[];
  }

  Future<void> setFoldersForChat(String cid, List<String> folders) async {
    await preferences.setStringList(key('chat_folder_assign.$cid'), folders);
    notifyListeners();
  }

  Future<void> toggleChatFolder(String cid, String folder) async {
    final current = getFoldersForChat(cid).toList();
    if (current.contains(folder)) {
      current.remove(folder);
    } else {
      current.add(folder);
    }
    await setFoldersForChat(cid, current);
  }

  double get voicePlaybackSpeed => preferences.getDouble(key('voice_playback_speed')) ?? 1.0;

  Future<void> setVoicePlaybackSpeed(double speed) async {
    await preferences.setDouble(key('voice_playback_speed'), speed);
    notifyListeners();
  }

  String get mediaQuality => preferences.getString(key('media_compression_quality')) ?? 'optimized';

  Future<void> setMediaQuality(String quality) async {
    await preferences.setString(key('media_compression_quality'), quality);
    notifyListeners();
  }

  bool get vaultBiometricsEnabled => preferences.getBool(key('vault.biometrics')) ?? false;

  Future<void> setVaultBiometrics(bool value) async {
    await preferences.setBool(key('vault.biometrics'), value);
    notifyListeners();
  }

  Future<void> initialize() async {
    lock.relockOnBackground =
        preferences.getBool(key('relock.background')) ?? true;
    lock.timeout = Duration(
      seconds: preferences.getInt(key('relock.seconds')) ?? 120,
    );
    lock.biometricsEnabled = preferences.getBool(key('biometrics')) ?? false;
    await lock.setShakeToLock(shakeToLock);
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
