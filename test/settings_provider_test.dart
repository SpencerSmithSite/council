import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:council/src/services/settings_provider.dart';
import 'package:council/src/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults to system theme, 1.0x text, citations on', () async {
    final settings = SettingsProvider();
    await settings.load();

    expect(settings.themeChoice, AppThemeChoice.system);
    expect(settings.themeMode, ThemeMode.system);
    expect(settings.fontScale, 1.0);
    expect(settings.showCitations, isTrue);
    expect(settings.isLoaded, isTrue);
  });

  test('persists and reloads each preference', () async {
    final settings = SettingsProvider();
    await settings.load();

    await settings.setThemeChoice(AppThemeChoice.catppuccinMocha);
    await settings.setFontScale(1.3);
    await settings.setShowCitations(false);

    final reloaded = SettingsProvider();
    await reloaded.load();

    expect(reloaded.themeChoice, AppThemeChoice.catppuccinMocha);
    // Catppuccin is a dark theme, so the derived mode is dark.
    expect(reloaded.themeMode, ThemeMode.dark);
    expect(reloaded.fontScale, closeTo(1.3, 0.001));
    expect(reloaded.showCitations, isFalse);
  });

  test('migrates the legacy dark_mode bool to a theme choice', () async {
    // A user who set Dark before named themes existed keeps that appearance.
    SharedPreferences.setMockInitialValues({'dark_mode': true});
    final settings = SettingsProvider();
    await settings.load();
    expect(settings.themeChoice, AppThemeChoice.dark);

    SharedPreferences.setMockInitialValues({'dark_mode': false});
    final light = SettingsProvider();
    await light.load();
    expect(light.themeChoice, AppThemeChoice.light);
  });

  test('notifies listeners so the widget tree rebuilds', () async {
    final settings = SettingsProvider();
    await settings.load();

    var notifications = 0;
    settings.addListener(() => notifications++);

    await settings.setThemeChoice(AppThemeChoice.light);
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

    await settings.setThemeChoice(AppThemeChoice.dark);
    await settings.setFontScale(1.5);
    await settings.resetAll();

    expect(settings.themeChoice, AppThemeChoice.system);
    expect(settings.fontScale, 1.0);
    expect(settings.showCitations, isTrue);
  });
}
