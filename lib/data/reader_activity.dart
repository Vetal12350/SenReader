import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

/// How many reader screens are currently mounted in this (UI) isolate.
///
/// Since Flutter merged the platform and UI threads, the app UI isolate and
/// the WorkManager background engine both run Dart on the Android main
/// thread. Chapter scans parse HTML/JSON and touch SQLite synchronously in
/// between network waits, which drops reader frames. While a reader is open,
/// scans in *any* isolate step aside; [marker] makes that visible across
/// isolates through a tiny file next to the app databases.
class ReaderActivity {
  ReaderActivity._();
  static final ValueNotifier<int> open = ValueNotifier<int>(0);
  static ReaderPresenceMarker marker = ReaderPresenceMarker();
  static bool get isOpen => open.value > 0;
  static void enter() {
    open.value++;
    if (open.value == 1) marker.start();
  }
  static void leave() {
    if (open.value == 0) return;
    open.value--;
    if (open.value == 0) marker.stop();
  }
}

/// Cross-isolate "reader is open" flag with a heartbeat: a killed process can
/// leave the file behind, so the stored value is an expiry time, not a bool.
class ReaderPresenceMarker {
  ReaderPresenceMarker({Future<String> Function()? directory,
    DateTime Function()? clock,
    this.ttl = const Duration(seconds: 90),
    this.heartbeat = const Duration(seconds: 30)})
      : _directory = directory ?? getDatabasesPath,
        _clock = clock ?? DateTime.now;
  final Future<String> Function() _directory;
  final DateTime Function() _clock;
  final Duration ttl, heartbeat;
  String? _path;
  Timer? _timer;
  Future<void> _writes = Future<void>.value();
  int _checkedAtMs = -1;
  bool _cached = false;

  Future<String> _resolve() async =>
      _path ??= '${await _directory()}${Platform.pathSeparator}senreader_reader_active';

  /// Resolve the file location up front so [activeNow] can stay synchronous.
  Future<void> prepare() async {
    try { await _resolve(); } catch (_) {}
  }

  void start() {
    _timer?.cancel();
    _enqueue(_write);
    _timer = Timer.periodic(heartbeat, (_) => _enqueue(_write));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _enqueue(_clear);
  }

  /// Completes when all queued marker writes have finished (tests, shutdown).
  Future<void> flush() => _writes;

  void _enqueue(Future<void> Function() step) {
    _writes = _writes.then((_) => step()).catchError((Object _) {});
  }

  Future<void> _write() async {
    final file = File(await _resolve());
    await file.writeAsString('${_clock().add(ttl).millisecondsSinceEpoch}');
  }

  Future<void> _clear() async {
    final file = File(await _resolve());
    if (await file.exists()) await file.delete();
  }

  /// Synchronous check for scan deadlines; re-reads the file at most once
  /// per second. Unknown location or unreadable file means "not reading".
  bool activeNow() {
    final path = _path;
    if (path == null) return false;
    final now = _clock().millisecondsSinceEpoch;
    if (_checkedAtMs >= 0 && now - _checkedAtMs < 1000) return _cached;
    _checkedAtMs = now;
    try {
      final file = File(path);
      final until = file.existsSync() ? int.tryParse(file.readAsStringSync().trim()) : null;
      _cached = until != null && until > now;
    } catch (_) {
      _cached = false;
    }
    return _cached;
  }
}

/// Runs work now, or — while a reader is open — keeps only the latest request
/// per [key] and runs it once the reader closes. For main-thread work that is
/// invisible during reading (cloud merges), so it cannot drop reader frames.
class ReaderDeferral {
  ReaderDeferral({ValueListenable<int>? reader})
      : _reader = reader ?? ReaderActivity.open {
    _reader.addListener(_onReaderChange);
  }
  final ValueListenable<int> _reader;
  final Map<String, void Function()> _pending = {};
  bool get reading => _reader.value > 0;
  bool get hasPending => _pending.isNotEmpty;

  /// Returns true when [action] ran immediately.
  bool run(String key, void Function() action) {
    if (!reading) {
      action();
      return true;
    }
    _pending.remove(key); // keep insertion order of the latest requests
    _pending[key] = action;
    return false;
  }

  void _onReaderChange() {
    if (reading || _pending.isEmpty) return;
    final actions = _pending.values.toList();
    _pending.clear();
    for (final action in actions) { action(); }
  }

  void dispose() {
    _reader.removeListener(_onReaderChange);
    _pending.clear();
  }
}
