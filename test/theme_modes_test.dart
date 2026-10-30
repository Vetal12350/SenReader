import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/chapter_alert_controller.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/data/theme_controller.dart';
import 'package:senreader/ui/app_theme.dart';
import 'package:senreader/ui/settings_page.dart';
import 'package:senreader/ui/widgets.dart';
import 'chapter_alert_opt_in_test.dart' show MemoryAlertPreferences;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults to existing dark mode and persists changes across controller instances', () async {
    final controller = ThemeController();
    await controller.load();
    expect(controller.mode, ThemeMode.dark);
    await controller.setMode(ThemeMode.light);
    final restored = ThemeController();
    await restored.load();
    expect(restored.mode, ThemeMode.light);
    await restored.setMode(ThemeMode.system);
    final third = ThemeController();
    await third.load();
    expect(third.mode, ThemeMode.system);
    expect(ThemeController.decode('malformed'), ThemeMode.dark);
  });

  testWidgets('settings theme chips update selection, and fit on small screens', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final themes = ThemeController();
    final alerts = ChapterAlertController(
      preferences: MemoryAlertPreferences()..shown = true,
      requestPermission: () async => false, sync: () async {});
    await tester.pumpWidget(MaterialApp(
      home: SettingsPage(repository: CatalogRepository(sources: {}),
        library: LibraryStore(), alerts: alerts, themes: themes),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('theme-dark')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Светлая'));
    await tester.pumpAndSettle();
    expect(themes.mode, ThemeMode.light);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Системная'));
    await tester.pumpAndSettle();
    expect(themes.mode, ThemeMode.system);
    expect(tester.takeException(), isNull);
  });

  testWidgets('light mode preserves readable catalog text and dark mode remains dark', (tester) async {
    final themes = ThemeController();
    Widget app() => AnimatedBuilder(animation: themes, builder: (context, _) =>
      MaterialApp(
        theme: SenReaderTheme.build(Brightness.light),
        darkTheme: SenReaderTheme.build(Brightness.dark),
        themeMode: themes.mode,
        home: Scaffold(body: ListView(children: const [
          SectionTitle('Каталог', subtitle: 'Senkuro · ReadManga · ReManga'),
          EmptyView(icon: Icons.search_off, text: 'Ничего не найдено'),
        ])),
      ));
    await tester.pumpWidget(app());
    expect(Theme.of(tester.element(find.text('Каталог'))).brightness, Brightness.dark);
    await themes.setMode(ThemeMode.light);
    await tester.pumpAndSettle();
    final theme = Theme.of(tester.element(find.text('Каталог')));
    expect(theme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor, const Color(0xFFFFFAF7));
    expect(tester.takeException(), isNull);
  });
}
