import 'dart:convert';
import 'dart:developer' show Timeline;
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

  // Recent reader events (monotonic µs, label) for slow-frame attribution.
  final _events = <(int, String)>[];
  int slowFramesLogged = 0;
  /// Record what the reader is doing; correlated with slow frames below.
  void note(String event) {
    _events.add((Timeline.now, event));
    if (_events.length > 64) _events.removeRange(0, _events.length - 64);
  }

  void add(List<FrameTiming> timings) {
    for (final frame in timings) {
      if (_build.length >= 12000) { truncated = true; break; }
      _build.add(frame.buildDuration.inMicroseconds);
      _raster.add(frame.rasterDuration.inMicroseconds);
      _logIfSlow(frame);
    }
  }

  /// One line per frame over 1.5× budget (max 200): phases plus the reader
  /// events from 150 ms before vsync to raster end. No titles or URLs.
  void _logIfSlow(FrameTiming frame) {
    final build = frame.buildDuration.inMicroseconds;
    final raster = frame.rasterDuration.inMicroseconds;
    if (math.max(build, raster) < budgetMicros * 1.5 || slowFramesLogged >= 200) return;
    slowFramesLogged++;
    final vsync = frame.timestampInMicroseconds(FramePhase.vsyncStart);
    final end = frame.timestampInMicroseconds(FramePhase.rasterFinish);
    final near = [for (final e in _events)
      if (e.$1 >= vsync - 150000 && e.$1 <= end + 5000) '${((e.$1 - vsync) / 1000).round()}ms:${e.$2}'];
    debugPrint('SenReader.SlowFrame ${jsonEncode({
      'vsyncUs': vsync, 'buildUs': build, 'rasterUs': raster,
      'uiStartDelayUs': frame.timestampInMicroseconds(FramePhase.buildStart) - vsync,
      'rasterWaitUs': frame.timestampInMicroseconds(FramePhase.rasterStart) -
          frame.timestampInMicroseconds(FramePhase.buildFinish),
      'layerCacheBytes': frame.layerCacheBytes, 'pictureCacheBytes': frame.pictureCacheBytes,
      'events': near})}');
  }

  Map<String, Object> report() {
    int percentile(List<int> source, double p) {
      if (source.isEmpty) return 0;
      final values = [...source]..sort();
      return values[(values.length * p).ceil() - 1];
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
      'uiP95Us': percentile(_build, .95), 'rasterP95Us': percentile(_raster, .95),
      'uiP99Us': percentile(_build, .99), 'rasterP99Us': percentile(_raster, .99),
      'uiMaxUs': _build.fold<int>(0, math.max),
      'rasterMaxUs': _raster.fold<int>(0, math.max),
      'uiOver50ms': _build.where((us) => us > 50000).length,
      'rasterOver50ms': _raster.where((us) => us > 50000).length,
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
