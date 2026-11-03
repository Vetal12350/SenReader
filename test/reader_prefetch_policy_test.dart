import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/ui/reader_prefetch_policy.dart';
import 'package:senreader/ui/reader_frame_metrics.dart';

void main() {
  test('direction, speed, boundaries and pressure bound the speculative window', () {
    List<int> plan(bool forward, double speed, {bool pressure = false}) =>
      ReaderPrefetchPolicy.candidates(first: 5, last: 6, count: 12,
        forward: forward, velocity: speed, viewport: 800, memoryPressure: pressure);
    expect(plan(true, 100), [7, 8, 4]);
    expect(plan(false, -1600), [4, 3, 2, 1, 7]);
    expect(plan(true, 1800, pressure: true), [7]);
    expect(ReaderPrefetchPolicy.candidates(first: 0, last: 1, count: 2,
      forward: false, velocity: 0, viewport: 800), isEmpty);
    expect(ReaderPrefetchPolicy.concurrency(80, 100), 1);
    expect(ReaderPrefetchPolicy.concurrency(10, 100), 2);
    expect(ReaderPrefetchPolicy.concurrency(0, 100, memoryPressure: true), 1);
    expect(ReaderPrefetchPolicy.decodedBytes(1200, 10), 57600000);
  });

  test('frame metrics distinguish UI/raster budget misses from geometry counters', () {
    final metrics = ReaderFrameMetrics(8333);
    metrics.add([
      FrameTiming(buildStart: 0, buildFinish: 4000, rasterStart: 5000, rasterFinish: 9000),
      FrameTiming(buildStart: 10000, buildFinish: 28000, rasterStart: 29000, rasterFinish: 33000),
    ]);
    final report = metrics.report();
    expect(report['frames'], 2);
    expect(report['overBudgetFrames'], 1);
    expect(report['estimatedMissedVsyncs'], 2);
    expect(report['idleAnchorCorrections'], 0);
    expect(report['uiP95Us'], 18000);
  });
}
