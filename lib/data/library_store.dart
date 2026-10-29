import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/models.dart';
import '../core/chapter_identity.dart';
import '../core/title_matching.dart';

class SavedBook {
  SavedBook({
    required this.title, required this.entries, this.lastChapter = '',
    this.lastSource = '', this.lastChapterId = '',
    this.lastPageIndex = 0, this.lastPageCount = 0, this.lastUpdatedAt = 0,
    Set<String>? readChapterKeys, Set<String>? seenChapterKeys,
    Set<String>? initializedSources,
  })  : readChapterKeys = readChapterKeys ?? <String>{},
        seenChapterKeys = seenChapterKeys ?? <String>{},
        initializedSources = initializedSources ?? <String>{};

  final String title;
  final Map<String, MangaEntry> entries;
  String lastChapter;
  String lastSource;
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
    'lastChapter': lastChapter, 'lastSource': lastSource,
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
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            final book = SavedBook.fromJson(Map<String, dynamic>.from(item as Map));
            if (book.key.isNotEmpty) _books[book.key] = book;
          }
        }
      } catch (_) {
        // Preserve malformed storage (do not overwrite it until user changes the library).
      }
    }
    notifyListeners();
  }

  bool has(UnifiedManga book) => _books.containsKey(normalizedTitle(book.title));
  SavedBook? get(UnifiedManga book) => _books[normalizedTitle(book.title)];

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(_books.values.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  Future<void> add(UnifiedManga book) async {
    final key = normalizedTitle(book.title);
    final current = _books[key];
    if (current == null) {
      _books[key] = SavedBook(title: book.title, entries: {...book.entries});
    } else {
      current.entries.addAll(book.entries);
    }
    await _save();
  }
  Future<void> remove(UnifiedManga book) async {
    _books.remove(normalizedTitle(book.title));
    await _save();
  }
  /// Commit a successful scan before surfacing its discoveries. A failing
  /// source never marks its baseline or clears previously seen chapters.
  Future<void> recordChapterScan(String bookKey, String source,
      Iterable<String> seenKeys) async {
    final item = _books[bookKey];
    if (item == null || !item.entries.containsKey(source)) return;
    item.seenChapterKeys.addAll(seenKeys);
    item.initializedSources.add(source);
    await _save();
  }

  /// Source-independent number/volume identity, or a source-scoped fallback.
  /// This remains stable when the chapter's subtitle changes.
  String _chapterKey(Chapter chapter, String source) =>
      canonicalChapterKey(chapter) ?? '$source:${chapter.id}';

  bool isChapterRead(UnifiedManga book, Chapter chapter, String source) {
    final saved = get(book);
    if (saved == null) return false;
    if (saved.readChapterKeys.contains(_chapterKey(chapter, source))) return true;
    // Existing v1 libraries stored only the last manually completed chapter.
    return saved.readChapterKeys.isEmpty && saved.lastChapterId.isEmpty &&
        saved.lastChapter == chapter.name && saved.lastSource == source;
  }

  /// Save where the reader stopped; do not mark the chapter completed.
  Future<void> savePosition(UnifiedManga book, Chapter chapter, String source,
      {required int pageIndex, required int pageCount}) async {
    final key = normalizedTitle(book.title);
    final item = _books.putIfAbsent(key,
        () => SavedBook(title: book.title, entries: {...book.entries}));
    item.entries.addAll(book.entries);
    item.lastChapter = chapter.name;
    item.lastChapterId = chapter.id;
    item.lastSource = source;
    item.lastPageCount = pageCount < 0 ? 0 : pageCount;
    item.lastPageIndex = pageIndex.clamp(0,
        item.lastPageCount > 0 ? item.lastPageCount - 1 : 0).toInt();
    item.lastUpdatedAt = DateTime.now().millisecondsSinceEpoch;
    await _save();
  }

  Future<void> markRead(UnifiedManga book, Chapter chapter, String source) async {
    final key = normalizedTitle(book.title);
    final item = _books.putIfAbsent(key,
        () => SavedBook(title: book.title, entries: {...book.entries}));
    item.entries.addAll(book.entries);
    if (item.lastChapterId != chapter.id || item.lastSource != source) {
      item.lastPageCount = 0;
    }
    item.lastChapter = chapter.name;
    item.lastChapterId = chapter.id;
    item.lastSource = source;
    item.lastPageIndex = item.lastPageCount > 0 ? item.lastPageCount - 1 : 0;
    item.readChapterKeys.add(_chapterKey(chapter, source));
    item.lastUpdatedAt = DateTime.now().millisecondsSinceEpoch;
    await _save();
  }

  Future<void> unmarkRead(UnifiedManga book, Chapter chapter, String source) async {
    final item = get(book);
    if (item == null) return;
    item.readChapterKeys.remove(_chapterKey(chapter, source));
    // Preserve the last reading position, even when a completion is undone.
    await _save();
  }
}
