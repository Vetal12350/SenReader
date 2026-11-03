import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Opt-in profile instrumentation, no book names, URLs or account information.
/// Flutter timings measure UI/raster work; estimated vsync misses are not an
/// Android SurfaceFlinger presentation/dropped-frame measurement.
class ReaderFrameMetrics {
  ReaderFrameMetrics(this.budgetMicros);
  final int budgetMicros;
  final _build = <int>[];
  final _raster = <int>[];
  int rootBuilds = 0, geometryCommits = 0, anchorCorrections = 0;
  int maxImageCacheBytes = 0;
  bool truncated = false;
  void readerBuilt() => rootBuilds++;
  void geometryCommitted() => geometryCommits++;
  void anchorCorrected() => anchorCorrections++;
  void sampleCache(int bytes) => maxImageCacheBytes = math.max(maxImageCacheBytes, bytes);

  void add(List<FrameTiming> timings) {
    for (final frame in timings) {
      if (_build.length >= 12000) { truncated = true; break; }
      _build.add(frame.buildDuration.inMicroseconds);
      _raster.add(frame.rasterDuration.inMicroseconds);
    }
  }

  Map<String, Object> report() {
    int percentile(List<int> source) {
      if (source.isEmpty) return 0;
      final values = [...source]..sort();
      return values[((values.length - 1) * .95).ceil()];
    }
    var overBudget = 0;
    var estimatedMisses = 0;
    for (var i = 0; i < _build.length; i++) {
      final longest = math.max(_build[i], _raster[i]);
      if (longest > budgetMicros) overBudget++;
      estimatedMisses += math.max(0, (longest / budgetMicros).ceil() - 1);
    }
    return {'frames': _build.length, 'budgetUs': budgetMicros,
      'overBudgetFrames': overBudget, 'estimatedMissedVsyncs': estimatedMisses,
      'uiP95Us': percentile(_build), 'rasterP95Us': percentile(_raster),
      'readerRootBuilds': rootBuilds, 'geometryCommits': geometryCommits,
      'idleAnchorCorrections': anchorCorrections,
      'maxImageCacheBytes': maxImageCacheBytes, 'truncated': truncated};
  }

  void start() => SchedulerBinding.instance.addTimingsCallback(add);
  void stop() {
    SchedulerBinding.instance.removeTimingsCallback(add);
    debugPrint('SenReader.ReaderFrames ${jsonEncode(report())}');
  }
}
