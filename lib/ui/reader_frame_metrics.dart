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

  // Scroll updates (monotonic µs). A frame that never started is invisible to
  // build/raster timings; detect it as a gap between frames during motion.
  final _motion = <int>[];
  int? _prevVsync;
  int frameGaps = 0, maxGapUs = 0, gapsLogged = 0;
  void motion([int? atUs]) {
    _motion.add(atUs ?? Timeline.now);
    if (_motion.length > 512) _motion.removeRange(0, _motion.length - 512);
  }

  void add(List<FrameTiming> timings) {
    for (final frame in timings) {
      if (_build.length >= 12000) { truncated = true; break; }
      _build.add(frame.buildDuration.inMicroseconds);
      _raster.add(frame.rasterDuration.inMicroseconds);
      _logIfSlow(frame);
      _detectGap(frame);
    }
  }

  void _detectGap(FrameTiming frame) {
    final vsync = frame.timestampInMicroseconds(FramePhase.vsyncStart);
    final prev = _prevVsync;
    _prevVsync = vsync;
    if (prev == null) return;
    final delta = vsync - prev;
    // Only gaps while the list was moving: an idle reader legitimately
    // produces no frames. Ignore long pauses (finger resting, > 0.5 s).
    if (delta < budgetMicros * 2.5 || delta > 500000) return;
    final moving = _motion.any((t) => t >= prev - 50000 && t <= vsync + 20000);
    if (!moving) return;
    frameGaps++;
    maxGapUs = math.max(maxGapUs, delta);
    if (gapsLogged >= 200) return;
    gapsLogged++;
    final near = [for (final e in _events)
      if (e.$1 >= prev - 100000 && e.$1 <= vsync + 5000) '${((e.$1 - prev) / 1000).round()}ms:${e.$2}'];
    debugPrint('SenReader.FrameGap ${jsonEncode({
      'fromVsyncUs': prev, 'gapUs': delta, 'nextBuildUs': frame.buildDuration.inMicroseconds,
      'nextRasterUs': frame.rasterDuration.inMicroseconds,
      'nextUiStartDelayUs': frame.timestampInMicroseconds(FramePhase.buildStart) - vsync,
      'events': near})}');
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
      'frameGapsWhileMoving': frameGaps, 'maxGapUs': maxGapUs,
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
