import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local-only display preference. Defaults to dark to preserve existing UX.
/// The preference is stored separately from the user's manga library.
class ThemeController extends ChangeNotifier {
  static const storageKey = 'senreader.theme.mode.v1';

  ThemeMode _mode = ThemeMode.dark;
  ThemeMode get mode => _mode;

  static ThemeMode decode(String? value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'system':
        return ThemeMode.system;
      case 'dark':
      default:
        return ThemeMode.dark;
    }
  }

  static String encode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.system:
        return 'system';
      case ThemeMode.dark:
        return 'dark';
    }
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = decode(prefs.getString(storageKey));
    notifyListeners();
  }

  Future<void> setMode(ThemeMode next) async {
    if (next == _mode) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, encode(next));
    _mode = next;
    notifyListeners();
  }
}
