import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/data/chapter_scan_schedule.dart';
import 'package:senreader/ui/chapter_notifications_panel.dart';

void main() {
  testWidgets('fresh start and finished worker show separate counts, completion and duration', (tester) async {
    final now = DateTime.now();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: ChapterScanDiagnostics(registrationSucceeded: true,
        lastRun: ChapterBackgroundScanSummary(at: now, origin: 'app',
          outcome: 'running', checkedSources: 0, skippedSources: 200,
          foundChapters: 0, warnings: 0, availableSources: 200),
        lastWorkerRun: ChapterBackgroundScanSummary(at: now.subtract(const Duration(minutes: 5)),
          finishedAt: now.subtract(const Duration(minutes: 4, seconds: 30)),
          checkedSources: 3, successfulSources: 2, failedSources: 1, skippedSources: 197,
          foundChapters: 4, warnings: 1, availableSources: 200, outcome: 'partial', reason: 'timeout',
          skipReasons: const {'budget': 197}, chapterDecisions: const {'baseline': 8},
          systemDelivery: 'permission_denied'),
      )))));
    expect(find.textContaining('Последняя проверка при открытии приложения'), findsOneWidget);
    expect(find.textContaining('Последняя задача WorkManager'), findsOneWidget);
    expect(find.textContaining('Выполняется; завершение ещё не подтверждено'), findsOneWidget);
    expect(find.textContaining('Длительность: 30 с'), findsOneWidget);
    expect(find.textContaining('успешно: 2, с ошибкой: 1'), findsOneWidget);
    expect(find.textContaining('сохранены как исходный список: 8'), findsOneWidget);
    expect(find.textContaining('Нет разрешения Android; внутренний inbox сохранён'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long diagnostic reasons wrap on a narrow display with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2)),
      child: Scaffold(body: SingleChildScrollView(child: ChapterScanDiagnostics(
        registrationSucceeded: false,
        lastRun: ChapterBackgroundScanSummary(at: DateTime.now(),
          checkedSources: 70, skippedSources: 130, foundChapters: 20, warnings: 2,
          outcome: 'partial', reason: 'lease', nextEligibleAt: DateTime.now()),
      ))))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Источников проверено: 70'), findsOneWidget);
  });

  testWidgets('no run is distinguishable from a zero-result or failed run', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ChapterScanDiagnostics())));
    expect(find.textContaining('ещё не запускалась'), findsOneWidget);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChapterScanDiagnostics(
      registrationSucceeded: false,
      lastRun: ChapterBackgroundScanSummary(at: DateTime(2026, 11, 2, 12),
        checkedSources: 0, skippedSources: 200, foundChapters: 0, warnings: 0,
        outcome: 'skipped', reason: 'cooldown', nextEligibleAt: DateTime(2026, 11, 3)),
    ))));
    expect(find.textContaining('HTTP 403/429'), findsOneWidget);
    expect(find.textContaining('отложено: 200'), findsOneWidget);
    expect(find.textContaining('Не удалось зарегистрировать'), findsOneWidget);
    expect(find.textContaining('02.11.2026'), findsOneWidget);
    expect(find.textContaining('Не ранее:'), findsOneWidget);
  });

  test('legacy summary decodes and new diagnostic fields stay UID-scoped', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('senreader.chapter_scan_last.v1.guest',
      '{"at":1793635200000,"checked":1,"skipped":0,"found":0,"warnings":1}');
    final store = ChapterScanScheduleStore();
    expect((await store.lastRun(''))!.outcome, 'partial');
    await store.recordRun('a', ChapterBackgroundScanSummary(at: DateTime.now(),
      checkedSources: 3, skippedSources: 7, foundChapters: 2, warnings: 0,
      outcome: 'running', origin: 'app', reason: 'budget'));
    await store.recordRegistration('a', success: false);
    expect((await store.lastRun('a'))!.origin, 'app');
    expect((await store.lastRun('a'))!.reason, 'budget');
    expect(await store.registrationSucceeded('a'), isFalse);
    expect(await store.lastRun('b'), isNull);
    expect(await store.registrationSucceeded(''), isNull);
    expect((await store.lastRun(''))!.checkedSources, 1);
    await store.recordRun('a', ChapterBackgroundScanSummary(at: DateTime.now(),
      checkedSources: 1, skippedSources: 0, foundChapters: 0, warnings: 0));
    await store.recordRun('a', ChapterBackgroundScanSummary(at: DateTime.now(),
      checkedSources: 0, skippedSources: 1, foundChapters: 0, warnings: 0,
      origin: 'app', outcome: 'skipped', reason: 'interval'));
    expect((await store.lastRun('a'))!.origin, 'app');
    expect((await store.lastRun('a', workmanagerOnly: true))!.checkedSources, 1);
  });
}
