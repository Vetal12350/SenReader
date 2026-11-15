import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import '../core/models.dart';

/// Downloads a fetched job list into [dir]; runs inside a background isolate.
typedef PageDownloader = Future<void> Function(
    String dir, List<Map<String, Object>> jobs, int concurrency);

/// Disk cache for chapter page images (C2), modelled on Mihon's ChapterCache:
/// pages of an opened chapter are downloaded ahead in a background isolate,
/// so scrolling reads local files instead of waiting for the network.
///
/// Only images the reader already received from the source are cached; it is
/// device-local, expires after [maxAge] and is bounded by [maxBytes]. It
/// holds no library, progress or account data and may be cleared any time.
class PageDiskCache {
  PageDiskCache({Future<String> Function()? root, this.maxBytes = 400 * 1024 * 1024,
    this.maxAge = const Duration(days: 1), this.concurrency = 3,
    PageDownloader? downloader, this.useIsolate = true})
      : _root = root ?? _defaultRoot,
        _downloader = downloader ?? downloadPages;

  static PageDiskCache instance = PageDiskCache();

  final Future<String> Function() _root;
  final int maxBytes, concurrency;
  final Duration maxAge;
  final PageDownloader _downloader;
  final bool useIsolate;
  String? _dir;
  Future<void> _queue = Future<void>.value();
  final Set<String> _queued = {};

  /// `<app data>/cache/senreader_pages`: Android's app cache directory, which
  /// the OS may also clear under storage pressure.
  static Future<String> _defaultRoot() async {
    final databases = await getDatabasesPath();
    return '${Directory(databases).parent.path}${Platform.pathSeparator}cache';
  }

  static final bool _underFlutterTest =
      Platform.environment.containsKey('FLUTTER_TEST');

  /// The shared instance is inert under `flutter test`: widget tests run on
  /// fake time where real file I/O never completes, and an isolate would
  /// bypass the test HTTP overrides. Cache tests use their own instance.
  bool get _disabled => useIsolate && _underFlutterTest;

  static String nameFor(String url) => sha1.convert(utf8.encode(url)).toString();

  Future<String> directory() async {
    final existing = _dir;
    if (existing != null) return existing;
    final dir = '${await _root()}${Platform.pathSeparator}senreader_pages';
    await Directory(dir).create(recursive: true);
    return _dir = dir;
  }

  /// Cached file for [url], or null when it is not (completely) on disk.
  Future<File?> cached(String url) async {
    if (_disabled) return null;
    try {
      final file = File('${await directory()}${Platform.pathSeparator}${nameFor(url)}');
      return await file.exists() && await file.length() > 0 ? file : null;
    } catch (_) {
      return null;
    }
  }

  /// Persist bytes fetched by the visible reader (atomic: tmp + rename).
  Future<void> store(String url, Uint8List bytes) async {
    if (bytes.isEmpty || _disabled) return;
    try {
      final path = '${await directory()}${Platform.pathSeparator}${nameFor(url)}';
      final tmp = File('$path.part');
      await tmp.writeAsBytes(bytes, flush: false);
      await tmp.rename(path);
    } catch (_) {/* Cache is best effort; reading still works from network. */}
  }

  /// Queue a chapter for background download, starting at [from]. Chapters
  /// are processed one at a time, so total concurrency stays bounded.
  Future<void> prefetch(List<PageImage> pages, {int from = 0}) {
    // Widget tests use fake page URLs; a background isolate would bypass the
    // test HTTP overrides and reach the real network.
    if (pages.isEmpty || _disabled) return _queue;
    final start = from.clamp(0, pages.length - 1).toInt();
    final ordered = [...pages.sublist(start), ...pages.sublist(0, start)]
        .where((page) => _queued.add(page.url)).toList();
    if (ordered.isEmpty) return _queue;
    final jobs = [for (final page in ordered)
      <String, Object>{'url': page.url, 'name': nameFor(page.url),
        'headers': Map<String, String>.from(page.headers)}];
    return _queue = _queue.then((_) async {
      try {
        final dir = await directory();
        final download = _downloader;
        final limit = concurrency;
        if (useIsolate) {
          await Isolate.run(() => download(dir, jobs, limit));
        } else {
          await download(dir, jobs, limit);
        }
      } catch (_) {
        // Best effort: the reader falls back to the network per page.
      } finally {
        for (final job in jobs) { _queued.remove(job['url']); }
      }
      await prune();
    });
  }

  /// Drop expired files, then the least recently written ones over budget.
  Future<void> prune() async {
    try {
      final dir = await directory();
      final limit = maxBytes;
      final ageMs = maxAge.inMilliseconds;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (useIsolate) {
        await Isolate.run(() => pruneDirectory(dir, limit, ageMs, nowMs));
      } else {
        await pruneDirectory(dir, limit, ageMs, nowMs);
      }
    } catch (_) {}
  }
}

/// Top-level so it can run in [Isolate.run]. Skips files already on disk.
Future<void> downloadPages(String dir, List<Map<String, Object>> jobs,
    int concurrency) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  var next = 0;
  Future<void> worker() async {
    while (next < jobs.length) {
      final job = jobs[next++];
      final path = '$dir${Platform.pathSeparator}${job['name']}';
      final file = File(path);
      if (await file.exists() && await file.length() > 0) continue;
      try {
        final request = await client.getUrl(Uri.parse(job['url']! as String))
            .timeout(const Duration(seconds: 20));
        (job['headers']! as Map<String, String>)
            .forEach((key, value) => request.headers.set(key, value));
        final response = await request.close().timeout(const Duration(seconds: 20));
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          continue; // Paid/protected/missing pages stay unavailable.
        }
        final tmp = File('$path.part');
        final sink = tmp.openWrite();
        await response.timeout(const Duration(seconds: 30)).pipe(sink);
        if (await tmp.length() > 0) await tmp.rename(path);
      } catch (_) {
        try { await File('$path.part').delete(); } catch (_) {}
      }
    }
  }
  try {
    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  } finally {
    client.close(force: true);
  }
}

/// Top-level so it can run in [Isolate.run].
Future<void> pruneDirectory(String dir, int maxBytes, int maxAgeMs, int nowMs) async {
  final entries = <(File, int, int)>[];
  await for (final entity in Directory(dir).list()) {
    if (entity is! File) continue;
    final stat = await entity.stat();
    final modified = stat.modified.millisecondsSinceEpoch;
    if (nowMs - modified > maxAgeMs) {
      try { await entity.delete(); } catch (_) {}
      continue;
    }
    entries.add((entity, stat.size, modified));
  }
  var total = entries.fold<int>(0, (sum, entry) => sum + entry.$2);
  entries.sort((a, b) => a.$3.compareTo(b.$3));
  for (final entry in entries) {
    if (total <= maxBytes) break;
    try { await entry.$1.delete(); total -= entry.$2; } catch (_) {}
  }
}
