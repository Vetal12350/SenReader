import 'dart:developer';

/// Opt-in diagnostic spans. Labels contain no titles, URLs or account data.
/// Async spans include I/O waits; they are not CPU duration measurements.
const readerTraceEnabled = bool.fromEnvironment('SENREADER_READER_TRACE');

/// Gesture boundaries only: no per-move logging, coordinates or reader data.
/// Keep source and callback clocks separate; this is not an input-latency claim.
void traceReaderInput(String phase, [Duration? eventTime]) {
  if (!readerTraceEnabled) return;
  Timeline.instantSync('SenReader.Input.$phase', arguments: {
    if (eventTime != null) 'sourceTimeUs': eventTime.inMicroseconds,
  });
}

Future<T> traceReaderTask<T>(String label, Future<T> Function() action) {
  if (!readerTraceEnabled) return action();
  return () async {
    final task = TimelineTask()..start(label);
    try {
      return await action();
    } finally {
      task.finish();
    }
  }();
}

T traceReaderWork<T>(String label, T Function() action) => readerTraceEnabled
    ? Timeline.timeSync(label, action) : action();
