import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/models.dart';
import '../core/chapter_identity.dart';
import '../core/title_matching.dart';

class SavedBook {
  SavedBook({
    required this.title, required this.entries, this.lastChapter = '',
    this.lastSource = '', this.status = 'planned', this.lastChapterId = '',
    this.lastPageIndex = 0, this.lastPageCount = 0, this.lastUpdatedAt = 0,
    Set<String>? readChapterKeys, Set<String>? seenChapterKeys,
    Set<String>? initializedSources,
    this.favorite = false,
    String preferredSource = '',
    int readHistoryVersion = 2,
  })  : readChapterKeys = readChapterKeys ?? <String>{},
        seenChapterKeys = seenChapterKeys ?? <String>{},
        initializedSources = initializedSources ?? <String>{},
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
    for (final source in const ['senkuro', 'readmanga', 'remanga']) {
      if (entries.containsKey(source)) return source;
    }
    final keys = entries.keys.toList()..sort();
    return keys.isEmpty ? '' : keys.first;
  }

  final String title;
  final Map<String, MangaEntry> entries;
  String lastChapter;
  String lastSource;
  String preferredSource;
  String status; // viewed, planned, reading, completed, dropped
  bool favorite;
  String lastChapterId;
  int lastPageIndex;
  int lastPageCount;
  int lastUpdatedAt;
  final Set<String> readChapterKeys;
  final Set<String> seenChapterKeys;
  final Set<String> initializedSources;
  String get key => normalizedTitle(title);
  UnifiedManga toUnified() => UnifiedManga(title: title, entries: {...entries});

  Map<String, dynamic> toJson() => {
    'title': title,
    'entries': entries.map((k, v) => MapEntry(k, v.toJson())),
    'lastChapter': lastChapter, 'lastSource': lastSource, 'status': status,
    'favorite': favorite,
    'preferredSource': preferredSource,
    'readHistoryVersion': 2,
    'lastChapterId': lastChapterId, 'lastPageIndex': lastPageIndex,
    'lastPageCount': lastPageCount, 'lastUpdatedAt': lastUpdatedAt,
    'readChapterKeys': readChapterKeys.toList()..sort(),
    'seenChapterKeys': seenChapterKeys.toList()..sort(),
    'initializedSources': initializedSources.toList()..sort(),
  };
  factory SavedBook.fromJson(Map<String, dynamic> json) {
    final raw = json['entries'] as Map? ?? {};
    return SavedBook(
      title: json['title'] as String? ?? '',
      entries: raw.map((k, v) => MapEntry(k.toString(), MangaEntry.fromJson(Map<String, dynamic>.from(v as Map)))),
      lastChapter: json['lastChapter'] as String? ?? '',
      lastSource: json['lastSource'] as String? ?? '',
      preferredSource: json['preferredSource'] as String? ?? '',
      readHistoryVersion: (json['readHistoryVersion'] as num?)?.toInt() ?? 1,
      favorite: json['favorite'] == true,
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
    );
  }
}

class LibraryStore extends ChangeNotifier {
  static const storageKey = 'senreader.library.v1';
  final Map<String, SavedBook> _books = {};
  List<SavedBook> get items => _books.values.toList();

  Future<void> load() async {
    await _reload();
    notifyListeners();
  }

  Future<void> _reload() async {
    final prefs = await SharedPreferences.getInstance();
    // Background WorkManager and the foreground have separate plugin caches.
    await prefs.reload();
    final raw = prefs.getString(storageKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final restored = <String, SavedBook>{};
          for (final item in decoded) {
            final book = SavedBook.fromJson(Map<String, dynamic>.from(item as Map));
            if (book.key.isNotEmpty) restored[book.key] = book;
          }
          _books..clear()..addAll(restored);
        }
      } catch (_) {
        // Preserve malformed storage (do not overwrite it until user changes the library).
      }
    }
  }

  bool has(UnifiedManga book) => _books.containsKey(normalizedTitle(book.title));
  SavedBook? get(UnifiedManga book) => _books[normalizedTitle(book.title)];

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(_books.values.map((e) => e.toJson()).toList()));
    notifyListeners();
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
      Iterable<String> seenKeys) async {
    await _reload();
    final item = _books[bookKey];
    if (item == null || item.preferredSource != source) return;
    item.seenChapterKeys.addAll(seenKeys);
    item.initializedSources.add(source);
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
        () => SavedBook(title: book.title, entries: {...book.entries}, preferredSource: source));
    if (item.preferredSource != source) return;
    for (final entry in book.entries.entries) {
      item.entries.putIfAbsent(entry.key, () => entry.value);
    }
    item.lastChapter = chapter.name;
    item.lastChapterId = chapter.id;
    item.lastSource = source;
    if (item.status == 'planned' || item.status == 'viewed') item.status = 'reading';
    item.lastPageCount = pageCount < 0 ? 0 : pageCount;
    item.lastPageIndex = pageIndex.clamp(0,
        item.lastPageCount > 0 ? item.lastPageCount - 1 : 0).toInt();
    item.lastUpdatedAt = DateTime.now().millisecondsSinceEpoch;
    await _save();
  }

  Future<void> markRead(UnifiedManga book, Chapter chapter, String source,
      {Iterable<Chapter> availableChapters = const []}) async {
    await _reload();
    final key = normalizedTitle(book.title);
    final item = _books.putIfAbsent(key,
        () => SavedBook(title: book.title, entries: {...book.entries}, preferredSource: source));
    if (item.preferredSource != source) return;
    for (final entry in book.entries.entries) {
      item.entries.putIfAbsent(entry.key, () => entry.value);
    }
    if (item.status == 'planned' || item.status == 'viewed') item.status = 'reading';
    item.readChapterKeys.add(sourceChapterKey(chapter, source));
    for (final candidate in availableChapters) {
      final order = compareChapterChronology(candidate, chapter);
      if (order != null && order <= 0) {
        item.readChapterKeys.add(sourceChapterKey(candidate, source));
      }
    }
    // Completion and resume are independent, including the current chapter.
    await _save();
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
