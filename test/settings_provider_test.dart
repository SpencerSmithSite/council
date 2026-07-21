import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theology_app/src/services/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults to system theme, 1.0x text, citations on', () async {
    final settings = SettingsProvider();
    await settings.load();

    expect(settings.themeMode, ThemeMode.system);
    expect(settings.fontScale, 1.0);
    expect(settings.showCitations, isTrue);
    expect(settings.isLoaded, isTrue);
  });

  test('persists and reloads each preference', () async {
    final settings = SettingsProvider();
    await settings.load();

    await settings.setThemeMode(ThemeMode.dark);
    await settings.setFontScale(1.3);
    await settings.setShowCitations(false);

    final reloaded = SettingsProvider();
    await reloaded.load();

    expect(reloaded.themeMode, ThemeMode.dark);
    expect(reloaded.fontScale, closeTo(1.3, 0.001));
    expect(reloaded.showCitations, isFalse);
  });

  test('notifies listeners so the widget tree rebuilds', () async {
    final settings = SettingsProvider();
    await settings.load();

    var notifications = 0;
    settings.addListener(() => notifications++);

    await settings.setThemeMode(ThemeMode.light);
    await settings.setFontScale(0.9);
    await settings.setShowCitations(false);

    expect(notifications, 3);
  });

  test('clamps font scale to the supported range', () async {
    final settings = SettingsProvider();
    await settings.load();

    await settings.setFontScale(5.0);
    expect(settings.fontScale, 1.5);

    await settings.setFontScale(0.1);
    expect(settings.fontScale, 0.8);
  });

  test('resetAll restores defaults', () async {
    final settings = SettingsProvider();
    await settings.load();

    await settings.setThemeMode(ThemeMode.dark);
    await settings.setFontScale(1.5);
    await settings.resetAll();

    expect(settings.themeMode, ThemeMode.system);
    expect(settings.fontScale, 1.0);
    expect(settings.showCitations, isTrue);
  });
}
