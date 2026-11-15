import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/data/chapter_alert_controller.dart';
import 'package:senreader/data/chapter_alert_preferences.dart';
import 'package:senreader/ui/chapter_alert_offer.dart';

class MemoryAlertPreferences extends ChapterAlertPreferences {
  bool shown = false;
  bool on = false;
  bool systemOn = false;
  @override Future<bool> offerShown() async => shown;
  @override Future<void> setOfferShown() async { shown = true; }
  @override Future<bool> enabled() async => on;
  @override Future<void> setEnabled(bool value) async { on = value; }
  @override Future<bool> systemNotificationsEnabled() async => systemOn;
  @override Future<void> setSystemNotificationsEnabled(bool value) async {
    systemOn = value;
  }
  @override Future<int> intervalMinutes() async => 15;
}

void main() {
  test('all former/default/sub-minimum intervals migrate to 15 minutes', () {
    for (final value in [null, -1, 0, 5, 14, 15, 30, 60, 180, 360, 9999]) {
      expect(ChapterAlertPreferences.migrateInterval(value), 60);
    }
    expect(ChapterAlertPreferences.availableIntervals, [15]);
    for (final value in [0, 5, 14, 30, 60]) {
      expect(() => ChapterAlertPreferences().setIntervalMinutes(value), throwsArgumentError);
    }
  });

  test('offer state persists independently of enabled and survives controller restart', () async {
    final prefs = MemoryAlertPreferences();
    var permissionRequests = 0;
    ChapterAlertController controller() => ChapterAlertController(preferences: prefs,
      requestPermission: () async { permissionRequests++; return false; }, sync: () async {});
    expect(await controller().claimOffer(), true);
    expect(prefs.on, false);
    expect(await controller().claimOffer(), false);
    expect(permissionRequests, 0);
    expect(await controller().setEnabled(true), true);
    expect(permissionRequests, 0);
    expect(prefs.on, true);
    expect(await controller().setSystemNotificationsEnabled(true), false);
    expect(permissionRequests, 1);
    expect(prefs.systemOn, false);
    // Android refusal must never turn off the internal scanner.
    expect(prefs.on, true);
    expect(await controller().claimOffer(), false);
  });

  test('explicit enable/disable synchronizes and failure leaves alerts off', () async {
    final prefs = MemoryAlertPreferences();
    var requests = 0;
    var syncs = 0;
    final alerts = ChapterAlertController(preferences: prefs,
      requestPermission: () async { requests++; return true; },
      sync: () async { syncs++; });
    expect(await alerts.setEnabled(true), true);
    expect(prefs.on, true);
    expect(await alerts.setEnabled(false), false);
    expect(prefs.on, false);
    expect(requests, 0);
    expect(syncs, 2);
    expect(await alerts.setEnabled(true), true);
    expect(await alerts.setSystemNotificationsEnabled(true), true);
    expect(requests, 1);
    expect(prefs.on, true);
    expect(prefs.systemOn, true);
    expect(await alerts.setSystemNotificationsEnabled(false), false);
    expect(prefs.systemOn, false);
    // The internal scanner stays enabled after OS alerts are turned off.
    expect(prefs.on, true);
    final broken = ChapterAlertController(preferences: prefs,
      requestPermission: () async => true,
      sync: () async => throw StateError('scheduler unavailable'));
    await expectLater(broken.setEnabled(true), throwsStateError);
    expect(prefs.on, false);
  });

  for (final accept in [false, true]) {
    testWidgets('offer requests Android permission only after affirmative action: $accept', (tester) async {
      final prefs = MemoryAlertPreferences();
      var requests = 0;
      final alerts = ChapterAlertController(preferences: prefs,
        requestPermission: () async { requests++; return false; }, sync: () async {});
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
        body: TextButton(onPressed: () => offerChapterAlerts(context, alerts),
          child: const Text('offer')),
      ))));
      await tester.tap(find.text('offer'));
      await tester.pumpAndSettle();
      expect(find.text('Включить фоновую проверку новых глав?'), findsOneWidget);
      expect(requests, 0);
      await tester.tap(find.text(accept ? 'Включить' : 'Не сейчас'));
      await tester.pumpAndSettle();
      expect(requests, 0);
      expect(prefs.on, accept);
      await tester.tap(find.text('offer'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(requests, 0);
    });
  }
}
