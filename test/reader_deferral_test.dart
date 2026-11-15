import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/data/reader_activity.dart';

/// Cloud sync merges run on the main thread the reader shares; while a
/// reader is open only the latest request per kind waits for it to close.
void main() {
  test('runs immediately when no reader is open', () {
    final reader = ValueNotifier<int>(0);
    final deferral = ReaderDeferral(reader: reader);
    var runs = 0;
    expect(deferral.run('local', () => runs++), isTrue);
    expect(runs, 1);
  });

  test('while reading keeps only the latest request per key, runs once on close', () {
    final reader = ValueNotifier<int>(1);
    final deferral = ReaderDeferral(reader: reader);
    final log = <String>[];
    expect(deferral.run('snapshot', () => log.add('snapshot-1')), isFalse);
    deferral.run('local', () => log.add('local-1'));
    deferral.run('snapshot', () => log.add('snapshot-2'));
    deferral.run('local', () => log.add('local-2'));
    expect(log, isEmpty, reason: 'no cloud merge while reading');
    reader.value = 2; // next chapter route on top
    reader.value = 1;
    expect(log, isEmpty);
    reader.value = 0;
    expect(log, ['snapshot-2', 'local-2']);
    reader.value = 1;
    reader.value = 0;
    expect(log, hasLength(2), reason: 'flushed work does not repeat');
  });

  test('dispose drops pending work and stops listening', () {
    final reader = ValueNotifier<int>(1);
    final deferral = ReaderDeferral(reader: reader);
    var runs = 0;
    deferral.run('local', () => runs++);
    deferral.dispose();
    reader.value = 0;
    expect(runs, 0);
  });
}
