import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/models.dart';
import '../core/chapter_identity.dart';
import 'chapter_inbox_store.dart';
import '../core/title_matching.dart';

class SavedBook {
  SavedBook({
    required this.title, required this.entries, this.lastChapter = '',
    this.lastSource = '', this.status = 'planned', this.lastChapterId = '',
    this.lastPageIndex = 0, this.lastPageCount = 0, this.lastUpdatedAt = 0,
    Set<String>? readChapterKeys, Set<String>? seenChapterKeys,
    Set<String>? initializedSources,
    Map<String, Set<String>>? sourceSeenChapterKeys,
    Map<String, int>? sourceChapterDates,
    this.favorite = false,
    this.syncEditedAt = 0,
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
  final Set<String> readChapterKeys;
  final Set<String> seenChapterKeys;
  final Set<String> initializedSources;
  final Map<String, Set<String>> sourceSeenChapterKeys;
  /// Genuine source-provided publication timestamps (UTC milliseconds).
  final Map<String, int> sourceChapterDates;
  String get key => normalizedTitle(title);
  UnifiedManga toUnified() => UnifiedManga(title: title, entries: {...entries});

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
    'readChapterKeys': readChapterKeys.toList()..sort(),
    'seenChapterKeys': seenChapterKeys.toList()..sort(),
    'initializedSources': initializedSources.toList()..sort(),
    'sourceSeenChapterKeys': sourceSeenChapterKeys.map((k, v) =>
        MapEntry(k, v.toList()..sort())),
    'sourceChapterDates': sourceChapterDates,
  };
  factory SavedBook.fromJson(Map<String, dynamic> json) {
    final raw = json['entries'] as Map? ?? {};
    return SavedBook(
      title: json['title'] as String? ?? '',
      entries: raw.map((k, v) => MapEntry(k.toString(), MangaEntry.fromJson(Map<String, dynamic>.from(v as Map)))),
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

  Future<void> _reload() async {
    final prefs = await SharedPreferences.getInstance();
    // Background WorkManager and the foreground have separate plugin caches.
    await prefs.reload();
    final raw = prefs.getString(_storageKey);
    _books.clear();
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
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
  }

  bool has(UnifiedManga book) => _books.containsKey(normalizedTitle(book.title));
  SavedBook? get(UnifiedManga book) => _books[normalizedTitle(book.title)];

  Future<void> _save({bool fromCloud = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (!fromCloud) {
      var clock = DateTime.now().microsecondsSinceEpoch;
      for (final entry in _books.entries) {
        if (_lastSavedPayload[entry.key] != _comparisonPayload(entry.value)) {
          clock = clock > entry.value.syncEditedAt ? clock : entry.value.syncEditedAt + 1;
          entry.value.syncEditedAt = clock++;
          _tombstones.remove(entry.key);
        }
      }
      for (final key in _lastSavedPayload.keys) {
        if (!_books.containsKey(key)) _tombstones[key] = clock++;
      }
    }
    await prefs.setString(_storageKey,
      jsonEncode(_books.values.map((e) => e.toJson()).toList()));
    await prefs.setString(_deletedKey, jsonEncode(_tombstones));
    _lastSavedPayload
      ..clear()
      ..addEntries(_books.entries.map((entry) =>
        MapEntry(entry.key, _comparisonPayload(entry.value))));
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
          book.syncEditedAt = revision;
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
      String? expectedProfile}) async {
    await _reload();
    if (expectedProfile != null && profileId != expectedProfile) return;
    final item = _books[bookKey];
    if (item == null || !item.entries.containsKey(source)) return;
    item.seenChapterKeys.addAll(seenKeys);
    item.sourceSeenChapterKeys.putIfAbsent(source, () => <String>{})
        .addAll(seenKeys);
    for (final chapter in sourceDates.entries) {
      if (chapter.value.year >= 2000) {
        item.sourceChapterDates['$source|${chapter.key}'] =
            chapter.value.toUtc().millisecondsSinceEpoch;
      }
    }
    item.initializedSources.add(source);
    await _save();
  }

  /// Record the newest VERIFIED chapter after a successful source detail load.
  /// A simple view must never add a title to bookmarks.
  Future<void> recordLatestChapter(UnifiedManga book, String source,
      Iterable<Chapter> chapters) async {
    final numbered = chapters.where((c) => canonicalChapterKey(c) != null)
        .toList();
    if (numbered.isEmpty) return;
    numbered.sort((a, b) => compareChapterChronology(a, b)!);
    final newest = numbered.last;
    await _reload();
    final item = get(book);
    if (item == null || item.preferredSource != source) return;
    if (item.latestKnownChapterId == newest.id &&
        item.latestKnownSource == source) return;
    item.latestKnownChapterId = newest.id;
    item.latestKnownSource = source;
    await _save();
  }

  bool isChapterRead(UnifiedManga book, Chapter chapter, String source) {
    final saved = get(book);
    if (saved == null) return false;
    return saved.readChapterKeys.contains(sourceChapterKey(chapter, source)) ||
        saved.readChapterKeys.contains('$source|id:name:${chapter.name}');
  }

  /// Save where the reader stopped; do not mark the chapter completed.
  Future<void> savePosition(UnifiedManga book, Chapter chapter, String source,
      {required int pageIndex, required int pageCount}) async {
    await _reload();
    final key = normalizedTitle(book.title);
    final item = _books.putIfAbsent(key,
        () => SavedBook(title: book.title, entries: {...book.entries},
          preferredSource: source, status: 'viewed'));
    if (item.preferredSource != source) return;
    for (final entry in book.entries.entries) {
      item.entries.putIfAbsent(entry.key, () => entry.value);
    }
    item.lastChapter = chapter.name;
    item.lastMarkedChapter = '';
    item.lastChapterId = chapter.id;
    item.lastSource = source;
    // Reading does not imply an explicit library subscription.
    item.lastPageCount = pageCount < 0 ? 0 : pageCount;
    item.lastPageIndex = pageIndex.clamp(0,
        item.lastPageCount > 0 ? item.lastPageCount - 1 : 0).toInt();
    item.lastUpdatedAt = DateTime.now().millisecondsSinceEpoch;
    await _save();
  }

  Future<void> markRead(UnifiedManga book, Chapter chapter, String source,
      {Iterable<Chapter> availableChapters = const [],
       bool userInitiated = false}) async {
    await _reload();
    final key = normalizedTitle(book.title);
    final item = _books.putIfAbsent(key,
        () => SavedBook(title: book.title, entries: {...book.entries},
          preferredSource: source, status: 'viewed'));
    if (item.preferredSource != source) return;
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
    await _save();
    try {
      await ChapterInboxStore().hideReadKeys(item.key, source, item.readChapterKeys);
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
      {Iterable<Chapter> availableChapters = const []}) async {
    await _reload();
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
      item.readChapterKeys.remove(sourceChapterKey(current, source));
      item.readChapterKeys.remove('$source|id:name:${current.name}');
      item.readChapterKeys.remove(canonicalChapterKey(current));
      item.readChapterKeys.remove('$source:${current.id}');
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
    await _save();
  }

  /// Only an explicit user selection changes a saved title's active source.
  Future<void> setPreferredSource(UnifiedManga book, String source) async {
    await _reload();
    final item = get(book);
    if (item == null || !book.entries.containsKey(source)) return;
    for (final entry in book.entries.entries) {
      item.entries.putIfAbsent(entry.key, () => entry.value);
    }
    item.preferredSource = source;
    await _save();
  }
}

