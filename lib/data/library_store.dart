import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/models.dart';
import '../core/title_matching.dart';

class SavedBook {
  SavedBook({
    required this.title, required this.entries, this.lastChapter = '',
    this.lastSource = '', Set<String>? seenChapterKeys,
    Set<String>? initializedSources,
  })  : seenChapterKeys = seenChapterKeys ?? <String>{},
        initializedSources = initializedSources ?? <String>{};

  final String title;
  final Map<String, MangaEntry> entries;
  String lastChapter;
  String lastSource;
  final Set<String> seenChapterKeys;
  final Set<String> initializedSources;
  String get key => normalizedTitle(title);
  UnifiedManga toUnified() => UnifiedManga(title: title, entries: {...entries});

  Map<String, dynamic> toJson() => {
    'title': title,
    'entries': entries.map((k, v) => MapEntry(k, v.toJson())),
    'lastChapter': lastChapter, 'lastSource': lastSource,
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

  Future<void> markRead(UnifiedManga book, Chapter chapter, String source) async {
    await add(book);
    final item = _books[normalizedTitle(book.title)]!;
    item.lastChapter = chapter.name;
    item.lastSource = source;
    await _save();
  }
}
