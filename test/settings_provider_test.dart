import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:council/src/services/settings_provider.dart';
import 'package:council/src/theme/app_theme.dart';
import 'package:council/src/theme/themes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults to system mode, Default theme, 1.0x text, citations on',
      () async {
    final settings = SettingsProvider();
    await settings.load();

    expect(settings.appThemeMode, AppThemeMode.system);
    expect(settings.themeId, kDefaultThemeId);
    expect(settings.themeMode, ThemeMode.system);
    expect(settings.fontScale, 1.0);
    expect(settings.showCitations, isTrue);
    expect(settings.isLoaded, isTrue);
  });

  test('persists and reloads mode and named theme independently', () async {
    final settings = SettingsProvider();
    await settings.load();

    await settings.setThemeMode(AppThemeMode.dark);
    await settings.setThemeId('dracula');
    await settings.setFontScale(1.3);
    await settings.setShowCitations(false);

    final reloaded = SettingsProvider();
    await reloaded.load();

    expect(reloaded.appThemeMode, AppThemeMode.dark);
    expect(reloaded.themeId, 'dracula');
    expect(reloaded.themeMode, ThemeMode.dark);
    expect(reloaded.fontScale, closeTo(1.3, 0.001));
    expect(reloaded.showCitations, isFalse);
  });

  test('migrates the legacy dark_mode bool to a brightness mode', () async {
    // A user who set Dark before named themes existed keeps that appearance,
    // on the Default theme.
    SharedPreferences.setMockInitialValues({'dark_mode': true});
    final settings = SettingsProvider();
    await settings.load();
    expect(settings.appThemeMode, AppThemeMode.dark);
    expect(settings.themeId, kDefaultThemeId);

    SharedPreferences.setMockInitialValues({'dark_mode': false});
    final light = SettingsProvider();
    await light.load();
    expect(light.appThemeMode, AppThemeMode.light);
    expect(light.themeId, kDefaultThemeId);
  });

  test('migrates the legacy catppuccinMocha choice to mode+theme', () async {
    // The old single-enum value carried both a brightness and a palette; it
    // splits into a dark mode and the catppuccin theme.
    SharedPreferences.setMockInitialValues({'theme_choice': 'catppuccinMocha'});
    final settings = SettingsProvider();
    await settings.load();
    expect(settings.appThemeMode, AppThemeMode.dark);
    expect(settings.themeId, 'catppuccin');
  });

  test('migrates a legacy plain light/dark choice, keeping Default', () async {
    SharedPreferences.setMockInitialValues({'theme_choice': 'dark'});
    final settings = SettingsProvider();
    await settings.load();
    expect(settings.appThemeMode, AppThemeMode.dark);
    expect(settings.themeId, kDefaultThemeId);
  });

  test('notifies listeners so the widget tree rebuilds', () async {
    final settings = SettingsProvider();
    await settings.load();

    var notifications = 0;
    settings.addListener(() => notifications++);

    await settings.setThemeMode(AppThemeMode.light);
    await settings.setThemeId('nord');
    await settings.setFontScale(0.9);
    await settings.setShowCitations(false);

    expect(notifications, 4);
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

    await settings.setThemeMode(AppThemeMode.dark);
    await settings.setThemeId('gruvbox');
    await settings.setFontScale(1.5);
    await settings.resetAll();

    expect(settings.appThemeMode, AppThemeMode.system);
    expect(settings.themeId, kDefaultThemeId);
    expect(settings.fontScale, 1.0);
    expect(settings.showCitations, isTrue);
  });
}
