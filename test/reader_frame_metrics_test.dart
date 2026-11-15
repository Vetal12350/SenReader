import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/ui/reader_frame_metrics.dart';

void main() {
  test('empty frame report has zero duration percentiles', () {
    final report = ReaderFrameMetrics(8333).report();
    for (final key in ['uiP95Us', 'uiP99Us', 'uiMaxUs', 'rasterP95Us',
        'rasterP99Us', 'rasterMaxUs', 'overBudgetFrames', 'uiOver50ms', 'rasterOver50ms']) {
      expect(report[key], 0, reason: key);
    }
  });

  test('UI and raster tails remain separate from presentation FPS', () {
    final metrics = ReaderFrameMetrics(8333);
    metrics.add([for (var i = 1; i <= 100; i++) FrameTiming(
      vsyncStart: 0, buildStart: 0, buildFinish: i * 1000,
      rasterStart: 100000, rasterFinish: 100000 + i * 500,
      rasterFinishWallTime: 100000 + i * 500)]);
    final report = metrics.report();
    expect(report['frames'], 100);
    expect(report['uiP95Us'], 95000);
    expect(report['uiP99Us'], 99000);
    expect(report['uiMaxUs'], 100000);
    expect(report['rasterP95Us'], 47500);
    expect(report['rasterP99Us'], 49500);
    expect(report['rasterMaxUs'], 50000);
    expect(report['uiOver50ms'], 50);
    expect(report['rasterOver50ms'], 0);
    expect(report.containsKey('fps'), isFalse);
  });
}
