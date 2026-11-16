import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/data/chapter_background_scheduler.dart';

/// A3: the foreground catch-up scan (UI isolate) must not run while a reader
/// is open, must run once the reader closes, and native registration must
/// never be delayed by either. testWidgets drives timers with fake time.
void main() {
  testWidgets('scan waits for the startup delay, then runs when no reader is open', (tester) async {
    var registered = 0, scans = 0;
    final catchUp = ChapterResumeCatchUp(
      register: () async { registered++; },
      scan: () async { scans++; },
      readerOpen: ValueNotifier<int>(0), delay: const Duration(seconds: 20));
    unawaited(catchUp.run());
    await tester.pump();
    expect(registered, 1, reason: 'native one-off task is not delayed');
    await tester.pump(const Duration(seconds: 19));
    expect(scans, 0);
    await tester.pump(const Duration(seconds: 2));
    expect(scans, 1);
  });

  testWidgets('open reader defers the scan until it closes, exactly once', (tester) async {
    var registered = 0, scans = 0;
    final reader = ValueNotifier<int>(1);
    final catchUp = ChapterResumeCatchUp(
      register: () async { registered++; },
      scan: () async { scans++; },
      readerOpen: reader, delay: const Duration(seconds: 20));
    unawaited(catchUp.run());
    await tester.pump(const Duration(seconds: 30));
    expect(scans, 0, reason: 'no UI-isolate scan while reading');
    // Resuming again while reading must not stack listeners.
    unawaited(catchUp.run());
    await tester.pump(const Duration(seconds: 30));
    expect(scans, 0);
    reader.value = 0;
    await tester.pump(const Duration(seconds: 21));
    expect(scans, 1);
    expect(registered, greaterThanOrEqualTo(2));
  });

  testWidgets('reader opening during the delay skips that scan', (tester) async {
    var scans = 0;
    final reader = ValueNotifier<int>(0);
    final catchUp = ChapterResumeCatchUp(register: () async {},
      scan: () async { scans++; },
      readerOpen: reader, delay: const Duration(seconds: 20));
    unawaited(catchUp.run());
    await tester.pump(const Duration(seconds: 5));
    reader.value = 1; // user opens a chapter from a notification
    await tester.pump(const Duration(seconds: 60));
    expect(scans, 0);
  });
}
