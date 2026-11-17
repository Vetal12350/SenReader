import 'dart:async';
import 'dart:math';
import 'dart:io';
import '../core/source.dart';
import 'package:flutter/foundation.dart';

/// Diagnostic only: never times out, cancels or changes a scan's result.
/// Call sites pass fixed stage codes, never titles, URLs, accounts or errors.
class ChapterScanTrace {
  ChapterScanTrace({void Function(String)? output,
    this.waitAfter = const Duration(seconds: 5)})
      : _output = output ?? debugPrintSynchronously,
        id = Random.secure().nextInt(0x7fffffff).toRadixString(16);
  final void Function(String) _output;
  final Duration waitAfter;
  final String id;
  final _clock = Stopwatch()..start();
  static const _key = #chapterScanTrace;
  static ChapterScanTrace? get current => Zone.current[_key] as ChapterScanTrace?;

  void event(String stage, String state) {
    try { _output('ChapterScan id=$id runId=$id utcMs=${DateTime.now().millisecondsSinceEpoch} ms=${_clock.elapsedMilliseconds} stage=$stage state=$state'); }
    catch (_) { /* Diagnostics must not affect persistence or completion. */ }
  }

  Future<T> step<T>(String stage, Future<T> Function() action) async {
    event(stage, 'begin');
    final waiting = Timer(waitAfter, () => event(stage, 'waiting'));
    try {
      final result = await action();
      event(stage, 'end');
      return result;
    } catch (error) {
      event(stage, error is TimeoutException ? 'timeout' : 'error');
      if (stage == 'source_pages') {
        event('source_pages_category', errorCategory(error));
        final detail = errorDetail(error);
        if (detail.isNotEmpty) event('source_pages_detail', detail);
      }
      rethrow;
    } finally {
      waiting.cancel();
    }
  }

  Future<T> run<T>(String origin, Future<T> Function() action) =>
      runZoned(() => step(origin, action), zoneValues: {_key: this});

  void androidStopped(String reason) {
    event('worker_stop_signal', reason);
    event('run_stop_category', 'cancelled');
  }

  /// Inspect only known error types; output is always a fixed allowlisted code.
  /// Source adapters may wrap causes; unmatched messages remain unknown.
  /// Which request failed and its HTTP status, e.g. `page_404`, `image_403`,
  /// `network`. Only a fixed label and a 3-digit code: never URLs or text.
  static String errorDetail(Object error) {
    if (error is SocketException || error is HttpException ||
        error is HandshakeException) {
      return 'network';
    }
    if (error is! SourceException) return '';
    final text = error.message.toLowerCase();
    final code = RegExp(r'http\s+(\d{3})').firstMatch(text)?.group(1);
    final kind = text.contains('изображен') ? 'image' : 'page';
    if (code != null) return '${kind}_$code';
    if (text.contains('нет соединения')) return 'network';
    return '';
  }

  static String errorCategory(Object error) {
    if (error is TimeoutException) return 'timeout';
    if (error is HttpException || error is SocketException || error is HandshakeException) {
      return 'http';
    }
    if (error is FormatException) return 'parse';
    if (error is SourceException) {
      final text = error.message.toLowerCase();
      if (RegExp(r'http\s+\d{3}').hasMatch(text)) return 'http';
      if (text.contains('время ожидания истекло')) return 'timeout';
      if (text.contains('нет соединения')) return 'http';
      if (text.contains('недоступн') || text.contains('публичном доступе') ||
          text.contains('заглушк')) {
        return 'unavailable';
      }
    }
    // No cancellation token/type exists in this scan path. Never infer
    // cancellation from arbitrary exception text or a late transport failure.
    return 'unknown';
  }

  final _processed = <String>{};
  void processed(String book) {
    if (_processed.add(book)) event('titles_processed', '${_processed.length}');
  }

  static Future<T> stage<T>(String name, Future<T> Function() action) =>
      current?.step(name, action) ?? action();
}
