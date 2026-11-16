import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/ui/battery_optimization_tile.dart';

class _FakeAccess extends BatteryOptimizationAccess {
  _FakeAccess(this.exempt, {this.grantOnRequest = true});
  bool exempt;
  final bool grantOnRequest;
  int requests = 0;
  @override Future<bool> isExempt() async => exempt;
  @override Future<bool> request() async {
    requests++;
    exempt = grantOnRequest;
    return exempt;
  }
}

Widget _app(BatteryOptimizationAccess access) => MaterialApp(home: Scaffold(
  body: BatteryOptimizationTile(access: access, androidOnly: false)));

void main() {
  testWidgets('restricted app shows the reason and asks only on tap', (tester) async {
    final access = _FakeAccess(false);
    await tester.pumpWidget(_app(access));
    await tester.pumpAndSettle();
    expect(find.textContaining('может откладывать проверки'), findsOneWidget);
    expect(access.requests, 0, reason: 'never prompts by itself');
    await tester.tap(find.text('Разрешить'));
    await tester.pumpAndSettle();
    expect(access.requests, 1);
    expect(find.textContaining('Разрешено'), findsOneWidget);
    expect(find.text('Разрешить'), findsNothing);
  });

  testWidgets('declined dialog keeps the button for a later retry', (tester) async {
    final access = _FakeAccess(false, grantOnRequest: false);
    await tester.pumpWidget(_app(access));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Разрешить'));
    await tester.pumpAndSettle();
    expect(find.text('Разрешить'), findsOneWidget);
  });

  testWidgets('already exempt shows no button', (tester) async {
    await tester.pumpWidget(_app(_FakeAccess(true)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Разрешено'), findsOneWidget);
    expect(find.text('Разрешить'), findsNothing);
  });

  testWidgets('a status read after returning from settings updates the tile', (tester) async {
    final access = _FakeAccess(false);
    await tester.pumpWidget(_app(access));
    await tester.pumpAndSettle();
    access.exempt = true; // changed in system settings
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.textContaining('Разрешено'), findsOneWidget);
  });
}
