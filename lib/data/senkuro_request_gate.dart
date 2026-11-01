import 'dart:async';
import 'dart:io';

/// Coordinates Senkuro requests so a throttled response cannot cause a
/// burst of immediate retries from concurrent UI and background operations.
class SenkuroRateLimited implements Exception {
  const SenkuroRateLimited(this.retryAfter);
  final Duration? retryAfter;
}

class SenkuroRequestGate {
  SenkuroRequestGate({
    this.minimumSpacing = const Duration(milliseconds: 250),
    this.fallbackDelay = const Duration(seconds: 4),
    this.maxAutomaticWait = const Duration(seconds: 20),
    this.maxRetries = 1,
    Future<void> Function(Duration)? sleeper,
  }) : _sleeper = sleeper;

  final Duration minimumSpacing;
  final Duration fallbackDelay;
  final Duration maxAutomaticWait;
  final int maxRetries;
  final Future<void> Function(Duration)? _sleeper;
  Future<void> _tail = Future<void>.value();
  DateTime _nextAllowed = DateTime.fromMillisecondsSinceEpoch(0);

  static Duration? parseRetryAfter(String? value, {DateTime? now}) {
    if (value == null || value.trim().isEmpty) return null;
    final text = value.trim();
    final seconds = int.tryParse(text);
    if (seconds != null) {
      return seconds < 0 ? Duration.zero : Duration(seconds: seconds);
    }
    try {
      final remaining = HttpDate.parse(text).difference(now ?? DateTime.now().toUtc());
      return remaining.isNegative ? Duration.zero : remaining;
    } on FormatException {
      return null;
    }
  }

  Future<void> _sleep(Duration duration) async {
    if (duration <= Duration.zero) return;
    if (_sleeper != null) return _sleeper(duration);
    await Future<void>.delayed(duration);
  }

  void _delayUntil(Duration duration) {
    final candidate = DateTime.now().add(duration);
    if (candidate.isAfter(_nextAllowed)) _nextAllowed = candidate;
  }

  /// Serializes requests including retry waits. This deliberately prioritizes
  /// respecting a server cooldown over throughput; no concurrent retry storm.
  Future<T> run<T>(Future<T> Function() operation) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return () async {
      try {
        await previous;
        for (var attempt = 0; ; attempt++) {
          await _sleep(_nextAllowed.difference(DateTime.now()));
          try {
            return await operation();
          } on SenkuroRateLimited catch (error) {
            // Respect a server-provided Retry-After even when too long to
            // keep the current title page loading for that whole period.
            final fallback = Duration(
              milliseconds: fallbackDelay.inMilliseconds * (attempt + 1));
            final delay = error.retryAfter ?? fallback;
            _delayUntil(delay);
            if (attempt >= maxRetries || delay > maxAutomaticWait) {
              throw StateError('Senkuro временно ограничил запросы');
            }
          } finally {
            _delayUntil(minimumSpacing);
          }
        }
      } finally {
        done.complete();
      }
    }();
  }
}
