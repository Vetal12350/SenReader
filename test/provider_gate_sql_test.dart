import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/data/chapter_scan_queue.dart';
import 'package:senreader/data/local_source_gate.dart';

void main() {
  test('gate waiting SQL attempts and error release', () async {
    final db = await ChapterScanQueue().database();
    await db.insert('providers', {'source': 'fixture', 'next': DateTime.now().millisecondsSinceEpoch + 1050});
    await db.execute('CREATE TABLE attempts (n INTEGER)');
    await db.execute('INSERT INTO attempts VALUES (0)');
    await db.execute('CREATE TRIGGER count_attempt BEFORE INSERT ON providers BEGIN UPDATE attempts SET n=n+1; END');
    final watch = Stopwatch()..start();
    await expectLater(LocalSourceGate('fixture').run<void>(() async { throw StateError('synthetic'); }), throwsStateError);
    final attempts = (await db.query('attempts')).single['n'] as int;
    debugPrint('gate inserts=$attempts elapsedMs=${watch.elapsedMilliseconds}');
    expect(attempts, 1);
    expect((await db.query('providers')).single['lease'], 0);
    await db.update('providers', {'next': 0});
    expect(await LocalSourceGate('fixture').run(() async => 7), 7);
  });
  test('concurrent gate requests do not overlap; expired wait does not call source', () async {
    final db = await ChapterScanQueue().database();
    final held = Completer<void>();
    final started = Completer<void>();
    final first = LocalSourceGate('fixture').run(() async { started.complete(); await held.future; });
    await started.future;
    var expired = false;
    var called = false;
    final second = runZoned(() => LocalSourceGate('fixture').run(() async { called = true; }), zoneValues: {LocalSourceGate.deadlineKey: () => expired});
    expired = true;
    await expectLater(second, throwsA(isA<TimeoutException>()));
    expect(called, false);
    held.complete(); await first;
    expect((await db.query('providers')).single['lease'], 0);
  });
}
