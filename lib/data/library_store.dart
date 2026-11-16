import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/models.dart';
import '../core/chapter_identity.dart';
import '../core/reader_trace.dart';
import 'chapter_inbox_store.dart';
import '../core/title_matching.dart';

/// An actual reader visit, independent of edits, discovery and sync revisions.
class ReadingVisit {
  const ReadingVisit({required this.source, required this.titleId,
    required this.chapterId, required this.chapterName, required this.pageIndex,
    required this.pageCount, required this.at});
  final String source, titleId, chapterId, chapterName;
  final int pageIndex, pageCount, at;
  Map<String, dynamic> toJson() => {'source': source, 'titleId': titleId,
    'chapterId': chapterId, 'chapterName': chapterName,
    'pageIndex': pageIndex, 'pageCount': pageCount, 'at': at};
  static ReadingVisit? fromJson(Object? raw) {
    if (raw is! Map || raw['source'] is! String || raw['titleId'] is! String ||
        raw['chapterId'] is! String || raw['chapterName'] is! String ||
        raw['at'] is! num || raw['pageIndex'] is! num || raw['pageCount'] is! num) return null;
    return ReadingVisit(source: raw['source'] as String, titleId: raw['titleId'] as String,
      chapterId: raw['chapterId'] as String, chapterName: raw['chapterName'] as String,
      pageIndex: (raw['pageIndex'] as num).toInt().clamp(0, 100000),
      pageCount: (raw['pageCount'] as num).toInt().clamp(0, 100000),
      at: (raw['at'] as num).toInt().clamp(0, 9999999999999));
  }
}

class SavedBook {
  SavedBook({
    required this.title, required this.entries, this.lastChapter = '',
    this.lastSource = '', this.status = 'planned', this.lastChapterId = '',
    this.lastPageIndex = 0, this.lastPageCount = 0, this.lastUpdatedAt = 0,
    Set<String>? readChapterKeys, Set<String>? seenChapterKeys,
    Set<String>? initializedSources,
    Map<String, Set<String>>? sourceSeenChapterKeys,
    Map<String, int>? sourceChapterDates,
    Map<String, int>? chapterPageIndexes,
    this.favorite = false,
    this.syncEditedAt = 0,
    this.lastReading,
    this.lastMarkedChapter = '',
    this.latestKnownChapterId = '',
    this.latestKnownSource = '',
    String preferredSource = '',
    int readHistoryVersion = 2,
  })  : readChapterKeys = readChapterKeys ?? <String>{},
        seenChapterKeys = seenChapterKeys ?? <String>{},
        initializedSources = initializedSources ?? <String>{},
        sourceSeenChapterKeys = sourceSeenChapterKeys ?? <String, Set<String>>{},
        sourceChapterDates = sourceChapterDates ?? <String, int>{},
        _chapterPageIndexes = chapterPageIndexes ?? <String, int>{},
        preferredSource = chooseSource(entries, preferredSource, lastSource) {
    // Preserve legacy keys, but attribute unscoped read history only to its
    // original source. Never project completion onto another translation.
    final historySource = entries.containsKey(lastSource) ? lastSource : '';
    for (final key in readHistoryVersion < 2 ? this.readChapterKeys.toList() : <String>[]) {
      if (key.startsWith('v') && historySource.isNotEmpty) {
        this.readChapterKeys.add('$historySource|$key');
      }
      for (final source in entries.keys) {
        if (key.startsWith('$source:')) {
          this.readChapterKeys.add('$source|id:${key.substring(source.length + 1)}');
        }
      }
    }
    if (readHistoryVersion < 2 && this.readChapterKeys.isEmpty && lastChapterId.isEmpty &&
        lastChapter.isNotEmpty && entries.containsKey(lastSource)) {
      this.readChapterKeys.add(sourceChapterKey(
          Chapter(id: 'name:$lastChapter', name: lastChapter), lastSource));
    }
  }

  static String chooseSource(Map<String, MangaEntry> entries,
      [String preferred = '', String last = '']) {
    if (entries.containsKey(preferred)) return preferred;
    if (entries.containsKey(last)) return last;
    for (final source in const ['senkuro', 'readmanga']) {
      if (entries.containsKey(source)) return source;
    }
    final keys = entries.keys.toList()..sort();
    return keys.isEmpty ? '' : keys.first;
  }

  final String title;
  final Map<String, MangaEntry> entries;
  String lastChapter;
  /// Manual eye taps may mark a chapter without moving the reader position.
  String lastMarkedChapter;
  /// Last confirmed chapter of this source, not inferred from user progress.
  String latestKnownChapterId;
  String latestKnownSource;
  String lastSource;
  String preferredSource;
  String status; // viewed, planned, reading, completed, dropped
  bool favorite;
  int syncEditedAt;
  String lastChapterId;
  int lastPageIndex;
  int lastPageCount;
  int lastUpdatedAt;
  ReadingVisit? lastReading;
  final Set<String> readChapterKeys;
  final Set<String> seenChapterKeys;
  final Set<String> initializedSources;
  final Map<String, Set<String>> sourceSeenChapterKeys;
  /// Genuine source-provided publication timestamps (UTC milliseconds).
  final Map<String, int> sourceChapterDates;
  // Recent nonzero positions, separate from the title's current resume target.
  static const _recentChapterLimit = 32;
  final Map<String, int> _chapterPageIndexes;
  static String _positionKey(String source, String id, String name) =>
      id.isEmpty ? '$source|name:$name' : '$source|id:$id';

  int pageIndexFor(Chapter chapter, String source) {
    if (lastSource == source && (lastChapterId.isNotEmpty
        ? lastChapterId == chapter.id : lastChapter == chapter.name)) {
      return lastPageIndex;
    }
    return _chapterPageIndexes[_positionKey(source, chapter.id, chapter.name)] ?? 0;
  }

  void _rememberPage(String source, String id, String name, int page) {
    if (source.isEmpty || (id.isEmpty && name.isEmpty)) return;
    final key = _positionKey(source, id, name);
    _chapterPageIndexes.remove(key);
    if (page <= 0) return;
    _chapterPageIndexes[key] = page;
    if (_chapterPageIndexes.length > _recentChapterLimit) {
      _chapterPageIndexes.remove(_chapterPageIndexes.keys.first);
    }
  }

  static Map<String, int> _decodeChapterPages(Object? raw) {
    if (raw is! List) return {};
    final pages = <String, int>{};
    for (final entry in raw) {
      if (entry is! Map) continue;
      final key = entry['key'];
      final page = entry['page'];
      if (key is String && page is int && page > 0 && page <= 100000) {
        pages[key] = page;
        if (pages.length > _recentChapterLimit) pages.remove(pages.keys.first);
      }
    }
    return pages;
  }
  String get key => normalizedTitle(title);
  UnifiedManga toUnified() => UnifiedManga(title: title, entries: {...entries});

  static List<String> _sortedHistory(Set<String> keys) {
    final list = keys.toList();
    // The persisted lists are already sorted. Sort only after an insertion
    // changes that order or when loading history from another format.
    for (var i = 1; i < list.length; i++) {
      if (list[i - 1].compareTo(list[i]) > 0) {
        list.sort();
        break;
      }
    }
    return list;
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'entries': entries.map((k, v) => MapEntry(k, v.toJson())),
    'lastChapter': lastChapter, 'lastSource': lastSource, 'status': status,
    'lastMarkedChapter': lastMarkedChapter,
    'latestKnownChapterId': latestKnownChapterId,
    'latestKnownSource': latestKnownSource,
    'favorite': favorite,
    'syncEditedAt': syncEditedAt,
    'preferredSource': preferredSource,
    'readHistoryVersion': 2,
    'lastChapterId': lastChapterId, 'lastPageIndex': lastPageIndex,
    'lastPageCount': lastPageCount, 'lastUpdatedAt': lastUpdatedAt,
    'lastReading': lastReading?.toJson(),
    if (_chapterPageIndexes.isNotEmpty)
      'chapterPageIndexes': [for (final entry in _chapterPageIndexes.entries)
        {'key': entry.key, 'page': entry.value}],
    'readChapterKeys': _sortedHistory(readChapterKeys),
    'seenChapterKeys': _sortedHistory(seenChapterKeys),
    'initializedSources': _sortedHistory(initializedSources),
    'sourceSeenChapterKeys': sourceSeenChapterKeys.map((k, v) =>
        MapEntry(k, _sortedHistory(v))),
    'sourceChapterDates': sourceChapterDates,
  };
  factory SavedBook.fromJson(Map<String, dynamic> json) {
    final raw = json['entries'] as Map? ?? {};
    return SavedBook(
      title: json['title'] as String? ?? '',
      entries: raw.map((k, v) => MapEntry(k.toString(), MangaEntry.fromJson(Map<String, dynamic>.from(v as Map)))),
      lastReading: json.containsKey('lastReading') ? ReadingVisit.fromJson(json['lastReading'])
          : ReadingVisit.fromJson({
              'source': json['lastSource'],
              'titleId': (raw[json['lastSource']] as Map?)?['id'],
              'chapterId': json['lastChapterId'] ?? '',
              'chapterName': json['lastChapter'] ?? '',
              'pageIndex': json['lastPageIndex'] ?? 0,
              'pageCount': json['lastPageCount'] ?? 0,
              'at': json['lastUpdatedAt'] ?? 0,
            }),
      lastChapter: json['lastChapter'] as String? ?? '',
      lastMarkedChapter: json['lastMarkedChapter'] as String? ?? '',
      latestKnownChapterId: json['latestKnownChapterId'] as String? ?? '',
      latestKnownSource: json['latestKnownSource'] as String? ?? '',
      lastSource: json['lastSource'] as String? ?? '',
      preferredSource: json['preferredSource'] as String? ?? '',
      readHistoryVersion: (json['readHistoryVersion'] as num?)?.toInt() ?? 1,
      favorite: json['favorite'] == true,
      syncEditedAt: (json['syncEditedAt'] as num?)?.toInt() ?? 0,
      status: ['viewed', 'planned', 'reading', 'completed', 'dropped'].contains(json['status'])
          ? json['status'] as String
          : ((json['lastChapter'] as String? ?? '').isEmpty ? 'planned' : 'reading'),
      lastChapterId: json['lastChapterId'] as String? ?? '',
      lastPageIndex: ((json['lastPageIndex'] as num?)?.toInt() ?? 0).clamp(0, 100000).toInt(),
      lastPageCount: ((json['lastPageCount'] as num?)?.toInt() ?? 0).clamp(0, 100000),
      lastUpdatedAt: ((json['lastUpdatedAt'] as num?)?.toInt() ?? 0).clamp(0, 9999999999999).toInt(),
      chapterPageIndexes: _decodeChapterPages(json['chapterPageIndexes']),
      readChapterKeys: (json['readChapterKeys'] is List
              ? (json['readChapterKeys'] as List).whereType<String>() : <String>[])
          .where((value) => value.length <= 256).toSet(),
      seenChapterKeys: (json['seenChapterKeys'] is List
              ? (json['seenChapterKeys'] as List).whereType<String>() : <String>[])
          .where((value) => value.length <= 128).toSet(),
      initializedSources: (json['initializedSources'] is List
              ? (json['initializedSources'] as List).whereType<String>() : <String>[])
          .where((value) => value.length <= 32).toSet(),
      sourceSeenChapterKeys: (json['sourceSeenChapterKeys'] is Map
          ? (json['sourceSeenChapterKeys'] as Map) : {}).map((k, v) =>
          MapEntry(k.toString(), v is List
              ? v.whereType<String>().where((x) => x.length <= 128).toSet()
              : <String>{})),
      sourceChapterDates: (json['sourceChapterDates'] is Map
          ? (json['sourceChapterDates'] as Map) : {}).map((k, v) =>
          MapEntry(k.toString(), v is num ? v.toInt() : 0)),
    );
  }
}

/// Validated, non-destructive library transfer for a one-time signing change.
class LibraryBackupPreview {
  const LibraryBackupPreview(this.books);
  final int books;
}

class LibraryStore extends ChangeNotifier {
  static const storageKey = 'senreader.library.v1';
  static const activeProfileKey = 'senreader.active.profile.v1';
  final Map<String, SavedBook> _books = {};
  final Map<String, int> _tombstones = {};
  final Map<String, String> _lastSavedPayload = {};
  // Exact storage strings this instance last decoded or wrote. When the
  // persisted strings are still identical, the in-memory books already
  // represent them and a hot-path write can skip a full decode/re-snapshot.
  bool _storageKnown = false;
  /// Number of full storage decodes; regression tests assert the hot path.
  @visibleForTesting
  int debugFullReloads = 0;
  String? _knownLibraryRaw;
  String? _knownDeletedRaw;
  String _storageKey = storageKey;
  String get profileId => _storageKey == storageKey ? '' :
      _storageKey.substring(storageKey.length + '.user.'.length);
  String get _deletedKey => '$_storageKey.deleted';
  static String _comparisonPayload(SavedBook book) =>
      jsonEncode(book.toJson()..remove('syncEditedAt'));

  Future<void> switchProfile(String? uid) async {
    final id = uid ?? '';
    if (id.isNotEmpty && !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id)) {
      throw ArgumentError('Invalid account identifier');
    }
    final target = id.isEmpty ? storageKey : '$storageKey.user.$id';
    if (target == _storageKey) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(activeProfileKey, id);
    _storageKey = target;
    _books.clear();
    _tombstones.clear();
    _lastSavedPayload.clear();
    await _reload();
    notifyListeners();
  }

  Future<({int added, int skipped})> importGuestLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return (added: 0, skipped: 0);
    final parsed = jsonDecode(raw);
    if (parsed is! List) throw const FormatException('Invalid guest data');
    return importBackup(jsonEncode({'format': _backupFormat, 'books': parsed}));
  }
  List<SavedBook> get items => _books.values.toList();

  static const _backupFormat = 'senreader.library.backup.v1';

  static List<SavedBook> _decodeBackup(String raw) {
    // A pasted backup is untrusted input; never import arbitrary prefs or keys.
    if (raw.length > 2000000) throw const FormatException('Копия слишком большая');
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['format'] != _backupFormat ||
        decoded['books'] is! List) {
      throw const FormatException('Неверный формат резервной копии');
    }
    final list = decoded['books'] as List;
    if (list.length > 10000) throw const FormatException('Слишком много произведений');
    final keys = <String>{};
    final restored = <SavedBook>[];
    for (final value in list) {
      if (value is! Map) throw const FormatException('Неверная запись произведения');
      final book = SavedBook.fromJson(Map<String, dynamic>.from(value));
      if (book.key.isEmpty || book.entries.isEmpty ||
          book.entries.entries.any((entry) =>
            entry.key.isEmpty || entry.value.id.isEmpty ||
            entry.value.source != entry.key) || !keys.add(book.key)) {
        throw const FormatException('Повреждена запись произведения');
      }
      restored.add(book);
    }
    return restored;
  }

  LibraryBackupPreview previewBackup(String raw) =>
      LibraryBackupPreview(_decodeBackup(raw).length);

  Future<String> exportBackup() async {
    await _reload();
    return jsonEncode({
      'format': _backupFormat,
      'books': _books.values.map((book) => book.toJson()).toList(),
    });
  }

  /// Existing on-device titles always win; no deletion or overwrite.
  Future<({int added, int skipped})> importBackup(String raw) async {
    final incoming = _decodeBackup(raw);
    await _reload();
    var added = 0;
    var skipped = 0;
    for (final book in incoming) {
      if (_books.containsKey(book.key)) {
        skipped++;
      } else {
        _books[book.key] = book;
        added++;
      }
    }
    if (added > 0) await _save();
    return (added: added, skipped: skipped);
  }


  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final id = prefs.getString(activeProfileKey) ?? '';
    _storageKey = id.isEmpty ? storageKey : '$storageKey.user.$id';
    await _reload();
    notifyListeners();
  }

  /// [load] for hot loops (the scheduled scanner): same profile resolution,
  /// but skips the full decode when this instance already holds exactly the
  /// persisted strings. Any change by another isolate triggers [load] logic.
  Future<void> loadIfChanged() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final id = prefs.getString(activeProfileKey) ?? '';
    final key = id.isEmpty ? storageKey : '$storageKey.user.$id';
    if (_storageKnown && key == _storageKey &&
        prefs.getString(_storageKey) == _knownLibraryRaw &&
        prefs.getString(_deletedKey) == _knownDeletedRaw) {
      return;
    }
    _storageKey = key;
    await _reload();
    notifyListeners();
  }

  Future<void> _reload() => traceReaderTask('SenReader.LibraryReload', _reloadImpl);

  Future<void> _reloadImpl() async {
    final prefs = await SharedPreferences.getInstance();
    // Background WorkManager and the foreground have separate plugin caches.
    await prefs.reload();
    final raw = prefs.getString(_storageKey);
    debugFullReloads++;
    _books.clear();
    _storageKnown = false;
    var decodedCleanly = raw == null;
    if (raw != null) {
      try {
        final decoded = traceReaderWork('SenReader.LibraryDecode', () => jsonDecode(raw));
        decodedCleanly = decoded is List;
        if (decoded is List) {
          final restored = <String, SavedBook>{};
          for (final item in decoded) {
            final book = SavedBook.fromJson(Map<String, dynamic>.from(item as Map));
            if (book.key.isNotEmpty) restored[book.key] = book;
          }
          _books.addAll(restored);
        }
      } catch (_) {
        // Preserve malformed storage (do not overwrite it until user changes the library).
        decodedCleanly = false;
      }
    }
    // Additive device-local scan state, scoped to the exact source ID. Legacy
    // fields stay intact; the scanner never writes the reading-history blob.
    final scanState = await ChapterInboxStore(profileId: profileId).loadScanState();
    for (final row in scanState) {
      final book = _books[row['book']];
      final source = row['source'] as String;
      if (book == null || book.entries[source]?.id != row['sourceId']) continue;
      final state = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      final seen = List<String>.from(state['seen'] as List);
      book.seenChapterKeys.addAll(seen);
      book.sourceSeenChapterKeys.putIfAbsent(source, () => <String>{}).addAll(seen);
      book.initializedSources.add(source);
      for (final entry in (state['dates'] as Map).entries) {
        book.sourceChapterDates['$source|${entry.key}'] = entry.value as int;
      }
    }
    _tombstones.clear();
    final rawDeleted = prefs.getString(_deletedKey);
    if (rawDeleted != null) {
      try {
        final decoded = jsonDecode(rawDeleted);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (entry.key is String && entry.value is num &&
                (entry.value as num).toInt() > 0) {
              _tombstones[entry.key as String] = (entry.value as num).toInt();
            }
          }
        }
      } catch (_) { /* Ignore malformed tombstones. */ }
    }
    _lastSavedPayload
      ..clear()
      ..addEntries(_books.entries.map((entry) =>
        MapEntry(entry.key, _comparisonPayload(entry.value))));
    // Malformed storage is never treated as known: every later write path
    // keeps re-reading it exactly as before.
    if (decodedCleanly) {
      _knownLibraryRaw = raw;
      _knownDeletedRaw = rawDeleted;
      _storageKnown = true;
    }
  }

  /// Hot reader path: re-read plugin storage (another isolate may have
  /// written), but skip the full decode when nothing changed since this
  /// instance last loaded or wrote it. Any difference falls back to [_reload].
  Future<void> _reloadIfChanged() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (_storageKnown &&
        prefs.getString(_storageKey) == _knownLibraryRaw &&
        prefs.getString(_deletedKey) == _knownDeletedRaw) {
      return;
    }
    await _reload();
  }

  bool has(UnifiedManga book) => _books.containsKey(normalizedTitle(book.title));
  SavedBook? get(UnifiedManga book) => _books[normalizedTitle(book.title)];

  Future<void> _save({bool fromCloud = false, String? expectedProfile}) =>
      traceReaderTask('SenReader.LibrarySave', () =>
        _saveImpl(fromCloud: fromCloud, expectedProfile: expectedProfile));

  Future<void> _saveImpl({bool fromCloud = false, String? expectedProfile}) async {
    final prefs = await SharedPreferences.getInstance();
    // Reader work may resume after a Google account switch.
    if (expectedProfile != null && profileId != expectedProfile) return;
    final savedStorageKey = _storageKey;
    final savedDeletedKey = _deletedKey;
    final savedBooks = <Map<String, dynamic>>[];
    final comparisons = <String, String>{};
    if (!fromCloud) {
      traceReaderWork('SenReader.LibraryRevisionScan', () {
        var clock = DateTime.now().microsecondsSinceEpoch;
        for (final entry in _books.entries) {
          final book = entry.value;
          final payload = book.toJson()..remove('syncEditedAt');
          final comparison = jsonEncode(payload);
          comparisons[entry.key] = comparison;
          if (_lastSavedPayload[entry.key] != comparison) {
            clock = clock > book.syncEditedAt ? clock : book.syncEditedAt + 1;
            book.syncEditedAt = clock++;
            _tombstones.remove(entry.key);
          }
          // Reuse the same snapshot, including the sorted chapter history.
          payload['syncEditedAt'] = book.syncEditedAt;
          savedBooks.add(payload);
        }
        for (final key in _lastSavedPayload.keys) {
          if (!_books.containsKey(key)) _tombstones[key] = clock++;
        }
      });
    }
    // Capture BOTH storage keys and payloads before awaiting plugin writes:
    // a switch must never redirect a pending write into the new account.
    final savedLibraryJson = traceReaderWork('SenReader.LibraryEncode', () =>
      jsonEncode(fromCloud ? _books.values.map((book) => book.toJson()).toList() : savedBooks));
    final savedTombstonesJson = jsonEncode(_tombstones);
    await prefs.setString(savedStorageKey, savedLibraryJson);
    await prefs.setString(savedDeletedKey, savedTombstonesJson);
    if (savedStorageKey != _storageKey) return;
    // Snapshot exactly what was written. Re-encoding after the awaits would
    // also mark a mutation made during the write as saved although it was not.
    traceReaderWork('SenReader.LibraryPayloadSnapshot', () {
      _lastSavedPayload.clear();
      if (fromCloud) {
        _lastSavedPayload.addEntries(_books.entries.map((entry) =>
          MapEntry(entry.key, _comparisonPayload(entry.value))));
      } else {
        _lastSavedPayload.addAll(comparisons);
      }
    });
    _knownLibraryRaw = savedLibraryJson;
    _knownDeletedRaw = savedTombstonesJson;
    _storageKnown = true;
    notifyListeners();
  }

  Future<Map<String, Map<String, dynamic>>> exportCloudRecords() async {
    await _reload();
    return {
      for (final item in _books.entries)
        item.key: {'editedAt': item.value.syncEditedAt,
          'deleted': false, 'book': item.value.toJson()},
      for (final removed in _tombstones.entries)
        if (!_books.containsKey(removed.key))
          removed.key: {'editedAt': removed.value, 'deleted': true},
    };
  }

  Future<int> mergeCloudRecords(Map<String, Map<String, dynamic>> cloud) async {
    await _reload();
    var changed = 0;
    for (final remote in cloud.entries) {
      final revision = (remote.value['editedAt'] as num?)?.toInt() ?? 0;
      if (revision <= 0) continue;
      final localRevision = _books[remote.key]?.syncEditedAt ??
          _tombstones[remote.key] ?? 0;
      if (revision <= localRevision) continue;
      if (remote.value['deleted'] == true) {
        _books.remove(remote.key);
        _tombstones[remote.key] = revision;
      } else {
        final raw = remote.value['book'];
        if (raw is! Map) continue;
        try {
          final book = SavedBook.fromJson(Map<String, dynamic>.from(raw));
          if (book.key != remote.key || book.entries.isEmpty ||
              book.entries.length > 8 ||
              book.entries.entries.any((e) => e.key.isEmpty ||
                e.value.id.isEmpty || e.value.source != e.key)) continue;
          final localVisit = _books[remote.key]?.lastReading;
          var readingMerged = false;
          if (localVisit != null && localVisit.at > (book.lastReading?.at ?? 0) &&
              book.entries[localVisit.source]?.id == localVisit.titleId) {
            readingMerged = true;
            book.lastReading = localVisit;
            final local = _books[remote.key]!;
            book.readChapterKeys.addAll(local.readChapterKeys.where(
              (key) => key.startsWith('${localVisit.source}|')));
            book._rememberPage(localVisit.source, localVisit.chapterId,
              localVisit.chapterName, localVisit.pageIndex);
            // A newer metadata revision must not discard more recent reading.
            if (book.entries[localVisit.source]?.id == localVisit.titleId) {
              book.lastSource = localVisit.source;
              book.lastChapterId = localVisit.chapterId;
              book.lastChapter = localVisit.chapterName;
              book.lastPageIndex = localVisit.pageIndex;
              book.lastPageCount = localVisit.pageCount;
              book.lastUpdatedAt = localVisit.at;
            }
          }
          book.syncEditedAt = readingMerged ? revision + 1 : revision;
          _books[remote.key] = book;
          _tombstones.remove(remote.key);
        } catch (_) { continue; }
      }
      changed++;
    }
    if (changed > 0) await _save(fromCloud: true);
    return changed;
  }

  /// Upgrade only the verified source rating on already-saved titles.
  /// Match source + stable slug exactly: never overwrite reading progress,
  /// saved status, chosen translation or other source metadata.
  Future<int> updateVerifiedRatings(Iterable<MangaEntry> entries) async {
    final ratings = <String, double>{};
    for (final entry in entries) {
      if (entry.source != 'senkuro' || entry.id.isEmpty) continue;
      final score = tenPointScore(entry.rating);
      if (score != null) ratings[entry.id] = score;
    }
    if (ratings.isEmpty) return 0;
    await _reload();
    var changed = 0;
    for (final saved in _books.values) {
      final original = saved.entries['senkuro'];
      if (original == null) continue;
      final score = ratings[original.id];
      if (score == null || score == original.rating) continue;
      saved.entries['senkuro'] = MangaEntry(
        source: original.source, id: original.id, title: original.title,
        remoteId: original.remoteId, coverUrl: original.coverUrl,
        tags: original.tags, rating: score);
      changed++;
    }
    if (changed != 0) await _save();
    return changed;
  }

  Future<void> add(UnifiedManga book, {String preferredSource = ''}) async {
    await _reload();
    final key = normalizedTitle(book.title);
    final current = _books[key];
    if (current == null) {
      _books[key] = SavedBook(title: book.title, entries: {...book.entries},
          preferredSource: preferredSource);
    } else {
      for (final entry in book.entries.entries) {
        current.entries.putIfAbsent(entry.key, () => entry.value);
      }
    }
    await _save();
  }
  /// Opening a new title records it separately without placing it in
  /// 'В планах'. Never downgrade an explicit library status.
  Future<void> markViewed(UnifiedManga book) async {
    await _reload();
    final key = normalizedTitle(book.title);
    if (!_books.containsKey(key)) {
      _books[key] = SavedBook(title: book.title, entries: {...book.entries},
        status: 'viewed');
    }
    await _save();
  }

  /// 'Любимое' is independent of reading status (e.g. favorite + reading).
  Future<void> setFavorite(UnifiedManga book, bool favorite,
      {String preferredSource = ''}) async {
    await _reload();
    final key = normalizedTitle(book.title);
    final item = _books.putIfAbsent(key,
      () => SavedBook(title: book.title, entries: {...book.entries},
        preferredSource: preferredSource, status: 'viewed'));
    item.favorite = favorite;
    await _save();
  }

  Future<void> remove(UnifiedManga book) async {
    await _reload();
    _books.remove(normalizedTitle(book.title));
    await _save();
  }
  /// Commit a successful scan before surfacing its discoveries. A failing
  /// source never marks its baseline or clears previously seen chapters.
  Future<void> recordChapterScan(String bookKey, String source,
      Iterable<String> seenKeys, {Map<String, DateTime> sourceDates = const {},
      String? expectedProfile, bool complete = false, String? expectedSourceId}) async {
    await _reload();
    if (expectedProfile != null && profileId != expectedProfile) return;
    final item = _books[bookKey];
    final sourceId = item?.entries[source]?.id;
    if (sourceId == null || (expectedSourceId != null && expectedSourceId != sourceId)) return;
    await ChapterInboxStore(profileId: profileId).recordScan(
        bookKey, source, sourceId, seenKeys, sourceDates, complete: complete);
    await _reload();
    notifyListeners();
  }

  /// Record the newest VERIFIED chapter after a successful source detail load.
  /// A simple view must never add a title to bookmarks.
  Future<void> recordLatestChapter(UnifiedManga book, String source,
      Iterable<Chapter> chapters, {String? expectedProfile}) async {
    final numbered = chapters.where((c) => canonicalChapterKey(c) != null)
        .toList();
    if (numbered.isEmpty) return;
    numbered.sort((a, b) => compareChapterChronology(a, b)!);
    final newest = numbered.last;
    await _reload();
    if (expectedProfile != null && profileId != expectedProfile) return;
    final item = get(book);
    if (item == null || item.preferredSource != source) return;
    if (item.latestKnownChapterId == newest.id &&
        item.latestKnownSource == source) return;
    item.latestKnownChapterId = newest.id;
    item.latestKnownSource = source;
    await _save(expectedProfile: expectedProfile);
  }

  bool isChapterRead(UnifiedManga book, Chapter chapter, String source) {
    final saved = get(book);
    if (saved == null) return false;
    return saved.readChapterKeys.contains(sourceChapterKey(chapter, source)) ||
        saved.readChapterKeys.contains('$source|id:name:${chapter.name}');
  }

  /// Save where the reader stopped; do not mark the chapter completed.
  Future<void> savePosition(UnifiedManga book, Chapter chapter, String source,
      {required int pageIndex, required int pageCount,
       String? expectedProfile}) async {
    // Called every few pages while reading: avoid a full library decode
    // unless storage changed underneath this instance.
    await _reloadIfChanged();
    if (expectedProfile != null && profileId != expectedProfile) return;
    final key = normalizedTitle(book.title);
    final item = _books.putIfAbsent(key,
        () => SavedBook(title: book.title, entries: {...book.entries},
          preferredSource: source, status: 'viewed'));
    if (item.preferredSource != source ||
        item.entries[source]?.id != book.entries[source]?.id) return;
    for (final entry in book.entries.entries) {
      item.entries.putIfAbsent(entry.key, () => entry.value);
    }
    item._rememberPage(item.lastSource, item.lastChapterId, item.lastChapter,
        item.lastPageIndex);
    item.lastChapter = chapter.name;
    item.lastMarkedChapter = '';
    item.lastChapterId = chapter.id;
    item.lastSource = source;
    // Reading does not imply an explicit library subscription.
    item.lastPageCount = pageCount < 0 ? 0 : pageCount;
    item.lastPageIndex = pageIndex.clamp(0,
        item.lastPageCount > 0 ? item.lastPageCount - 1 : 0).toInt();
    item._rememberPage(source, chapter.id, chapter.name, item.lastPageIndex);
    item.lastUpdatedAt = DateTime.now().millisecondsSinceEpoch;
    item.lastReading = ReadingVisit(source: source, titleId: item.entries[source]!.id,
      chapterId: chapter.id, chapterName: chapter.name,
      pageIndex: item.lastPageIndex, pageCount: item.lastPageCount, at: item.lastUpdatedAt);
    await _save(expectedProfile: expectedProfile);
  }

  Future<void> markRead(UnifiedManga book, Chapter chapter, String source,
      {Iterable<Chapter> availableChapters = const [],
       bool userInitiated = false, String? expectedProfile}) async {
    await _reload();
    if (expectedProfile != null && profileId != expectedProfile) return;
    final key = normalizedTitle(book.title);
    final item = _books.putIfAbsent(key,
        () => SavedBook(title: book.title, entries: {...book.entries},
          preferredSource: source, status: 'viewed'));
    if (item.preferredSource != source ||
        item.entries[source]?.id != book.entries[source]?.id) return;
    for (final entry in book.entries.entries) {
      item.entries.putIfAbsent(entry.key, () => entry.value);
    }
    // An eye tap is an explicit reading-list choice; opening a reader is not.
    if (userInitiated) {
      item.status = 'reading';
      item.lastMarkedChapter = chapter.name;
    }
    item.readChapterKeys.add(sourceChapterKey(chapter, source));
    for (final candidate in availableChapters) {
      final order = compareChapterChronology(candidate, chapter);
      if (order != null && order <= 0) {
        item.readChapterKeys.add(sourceChapterKey(candidate, source));
      }
    }
    // Completion and resume are independent, including the current chapter.
    await _save(expectedProfile: expectedProfile);
    if (expectedProfile != null && profileId != expectedProfile) return;
    try {
      await ChapterInboxStore(profileId: profileId).hideReadKeys(item.key, source,
        userInitiated ? item.readChapterKeys : {sourceChapterKey(chapter, source)});
    } catch (_) {
      // An unavailable notification store must not roll back reading progress.
    }
  }

  Future<void> setStatus(UnifiedManga book, String status, {String preferredSource = ''}) async {
    if (!['viewed', 'planned', 'reading', 'completed', 'dropped'].contains(status)) return;
    await add(book, preferredSource: preferredSource);
    _books[normalizedTitle(book.title)]!.status = status;
    await _save();
  }

  /// Unreading chapter N clears N and every chronologically newer chapter
  /// for that same source, never an older chapter or a different translation.
  /// Unknown/special labels can only remove their exact key.
  Future<void> unmarkRead(UnifiedManga book, Chapter chapter, String source,
      {Iterable<Chapter> availableChapters = const [],
       String? expectedProfile}) async {
    await _reload();
    if (expectedProfile != null && profileId != expectedProfile) return;
    final item = get(book);
    if (item == null || item.preferredSource != source) return;
    final affected = <Chapter>[chapter];
    if (canonicalChapterKey(chapter) != null) {
      for (final candidate in availableChapters) {
        final order = compareChapterChronology(candidate, chapter);
        if (order != null && order >= 0) affected.add(candidate);
      }
    }
    for (final current in affected) {
      item._chapterPageIndexes.remove(SavedBook._positionKey(source, current.id, current.name));
      item.readChapterKeys.remove(sourceChapterKey(current, source));
      item.readChapterKeys.remove('$source|id:name:${current.name}');
      item.readChapterKeys.remove(canonicalChapterKey(current));
      item.readChapterKeys.remove('$source:${current.id}');
    }
    // Preserve the preceding resume target if the unread operation leaves it intact.
    if (!affected.any((current) => item.lastSource == source &&
        (item.lastChapterId.isNotEmpty ? current.id == item.lastChapterId :
          current.name == item.lastChapter))) {
      item._rememberPage(item.lastSource, item.lastChapterId, item.lastChapter,
          item.lastPageIndex);
    }
    // Explicit unread resets both the resume chapter and its saved page.
    item.lastChapter = chapter.name;
    item.lastMarkedChapter = '';
    item.lastChapterId = chapter.id;
    item.lastSource = source;
    item.lastPageIndex = 0;
    item.lastPageCount = 0;
    item.lastUpdatedAt = DateTime.now().millisecondsSinceEpoch;
    // Historical canonical completions can outlive the currently loaded
    // chapter page. Clear newer scoped canonical keys too; never alter other
    // sources and never infer ordering for unparseable specials.
    final boundary = canonicalChapterKey(chapter);
    if (boundary != null) {
      item.readChapterKeys.removeWhere((key) {
        final prefix = '$source|';
        if (!key.startsWith(prefix + 'v')) return false;
        final canonical = key.substring(prefix.length);
        final parts = RegExp(r'^v([0-9]+(?:\.[0-9]+)?):c([0-9]+(?:\.[0-9]+)?)$').firstMatch(canonical);
        if (parts == null) return false;
        final parsed = Chapter(id: canonical,
          name: 'Глава ${parts.group(2)} (т. ${parts.group(1)})');
        return (compareChapterChronology(parsed, chapter) ?? -1) >= 0;
      });
    }
    await _save(expectedProfile: expectedProfile);
  }

  /// Only an explicit user selection changes a saved title's active source.
  Future<void> setPreferredSource(UnifiedManga book, String source, {String? expectedProfile}) async {
    await _reload();
    if (expectedProfile != null && profileId != expectedProfile) return;
    final item = get(book);
    if (item == null || !book.entries.containsKey(source)) return;
    for (final entry in book.entries.entries) {
      item.entries.putIfAbsent(entry.key, () => entry.value);
    }
    item.preferredSource = source;
    await _save(expectedProfile: expectedProfile);
  }
}

