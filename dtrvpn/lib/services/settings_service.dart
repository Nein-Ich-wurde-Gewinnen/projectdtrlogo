import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService extends ChangeNotifier {
  static SettingsService? _instance;
  static SettingsService get instance => _instance ??= SettingsService._();
  SettingsService._();

  SharedPreferences? _prefs;

  static const _keyPingUrl = 'ping_url';
  static const _keySeedColor = 'seed_color';
  static const _keyThemeMode = 'theme_mode';

  static const defaultPingUrl = 'http://www.gstatic.com/generate_204';

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // ── Ping URL ──────────────────────────────────────────────────────────────
  String get pingUrl => _prefs?.getString(_keyPingUrl) ?? defaultPingUrl;
  Future<void> setPingUrl(String url) async {
    await _prefs?.setString(_keyPingUrl, url);
    notifyListeners();
  }

  // ── Seed Color ────────────────────────────────────────────────────────────
  Color get seedColor =>
      Color(_prefs?.getInt(_keySeedColor) ?? 0xFF1A73E8);
  Future<void> setSeedColor(Color color) async {
    await _prefs?.setInt(_keySeedColor, color.toARGB32());
    notifyListeners();
  }

  // ── Theme Mode ────────────────────────────────────────────────────────────
  ThemeMode get themeMode {
    switch (_prefs?.getString(_keyThemeMode)) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final val = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      _ => 'system',
    };
    await _prefs?.setString(_keyThemeMode, val);
    notifyListeners();
  }
}
