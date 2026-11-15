import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/ui/reader_prefetch_policy.dart';
import 'package:senreader/ui/reader_frame_metrics.dart';
import 'package:flutter/painting.dart' show ImageCache;
import 'package:senreader/ui/reader_page.dart' show ReaderImageBudget;

void main() {
  test('reader raises the bitmap budget only while open; pressure gives it back', () {
    final cache = ImageCache()..maximumSizeBytes = 100 << 20..maximumSize = 1000;
    final budget = ReaderImageBudget(cache: cache);
    budget.enter();
    expect(cache.maximumSizeBytes, ReaderPrefetchPolicy.readerCacheBytes);
    expect(cache.maximumSize, 1000, reason: 'never lowers an existing limit');
    budget.enter(); // nested reader (next chapter route)
    budget.leave();
    expect(cache.maximumSizeBytes, ReaderPrefetchPolicy.readerCacheBytes);
    budget.leave();
    expect(cache.maximumSizeBytes, 100 << 20);
    budget.enter();
    budget.release(); // memory pressure while reading
    expect(cache.maximumSizeBytes, 100 << 20);
    budget.leave();
    expect(cache.maximumSizeBytes, 100 << 20);
  });

  test('direction, speed, boundaries and pressure bound the speculative window', () {
    List<int> plan(bool forward, double speed, {bool pressure = false}) =>
      ReaderPrefetchPolicy.candidates(first: 5, last: 6, count: 12,
        forward: forward, velocity: speed, viewport: 800, memoryPressure: pressure);
    expect(plan(true, 100), [7, 8, 9, 10, 4]);
    expect(plan(false, -1600), [4, 3, 2, 1, 0, 7]);
    expect(plan(true, 1800, pressure: true), [7]);
    expect(ReaderPrefetchPolicy.candidates(first: 0, last: 1, count: 2,
      forward: false, velocity: 0, viewport: 800), isEmpty);
    expect(ReaderPrefetchPolicy.concurrency(95, 100), 1);
    expect(ReaderPrefetchPolicy.concurrency(80, 100), 2);
    expect(ReaderPrefetchPolicy.concurrency(10, 100), 3);
    expect(ReaderPrefetchPolicy.concurrency(0, 100, memoryPressure: true), 1);
    expect(ReaderPrefetchPolicy.decodedBytes(1200, 10), 57600000);
  });

  test('frame gaps count only while the list is moving', () {
    final metrics = ReaderFrameMetrics(8333);
    FrameTiming at(int vsync) => FrameTiming(vsyncStart: vsync, buildStart: vsync,
      buildFinish: vsync + 1000, rasterStart: vsync + 1500, rasterFinish: vsync + 3000,
      rasterFinishWallTime: vsync + 3000);
    metrics.motion(10000);
    metrics.add([at(0), at(8333), at(60000)]); // 51.7 ms gap during a drag
    metrics.add([at(2000000), at(2060000)]); // idle: no motion around it
    final report = metrics.report();
    expect(report['frameGapsWhileMoving'], 1);
    expect(report['maxGapUs'], 51667);
  });

  test('frame metrics distinguish UI/raster budget misses from geometry counters', () {
    final metrics = ReaderFrameMetrics(8333);
    metrics.add([
      FrameTiming(vsyncStart: 0, buildStart: 0, buildFinish: 4000,
        rasterStart: 5000, rasterFinish: 9000, rasterFinishWallTime: 9000),
      FrameTiming(vsyncStart: 10000, buildStart: 10000, buildFinish: 28000,
        rasterStart: 29000, rasterFinish: 33000, rasterFinishWallTime: 33000),
    ]);
    final report = metrics.report();
    expect(report['frames'], 2);
    expect(report['overBudgetFrames'], 1);
    expect(report['estimatedMissedVsyncs'], 2);
    expect(report['idleAnchorCorrections'], 0);
    expect(report['uiP95Us'], 18000);
  });
}
