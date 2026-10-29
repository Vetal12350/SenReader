import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/chapter_updates.dart';
import '../core/models.dart';
import '../core/title_matching.dart';
import 'chapter_checker.dart';

class ReadingProgress {
  const ReadingProgress({required this.source, required this.chapter});
  final String source;
  final Chapter chapter;
  Map<String, dynamic> toJson() => {'source': source, 'chapter': chapter.toJson()};
  factory ReadingProgress.fromJson(Map<String, dynamic> json) => ReadingProgress(
    source: json['source'] as String,
    chapter: Chapter.fromJson(Map<String, dynamic>.from(json['chapter'] as Map)));
}

class SavedBook {
  SavedBook({required this.title, required this.entries, String? id,
    this.lastChapter = '', this.lastSource = '', List<ReadingProgress>? progress,
    ChapterUpdateState? updates, this.requiresLinkApproval = false})
      : id = id ?? 'book:${jsonEncode([entries.values.first.source, entries.values.first.id])}',
        progress = progress ?? [], updates = updates ?? ChapterUpdateState();
  final String id;
  final String title;
  bool requiresLinkApproval;
  final Map<String, MangaEntry> entries;
  String lastChapter;
  String lastSource;
  final List<ReadingProgress> progress;
  ChapterUpdateState updates;
  String get key => id;
  UnifiedManga toUnified() => UnifiedManga(title: title, entries: {...entries}, savedId: id,
    requiresLinkApproval: requiresLinkApproval);

  Map<String, dynamic> toJson() => {
    'id': id, 'title': title,
    'requiresLinkApproval': requiresLinkApproval,
    'entries': entries.map((k, v) => MapEntry(k, v.toJson())),
    'lastChapter': lastChapter, 'lastSource': lastSource,
    'progress': progress.map((p) => p.toJson()).toList(),
    'updates': updates.toJson(),
  };
  factory SavedBook.fromJson(Map<String, dynamic> json, {String? legacyId}) {
    if (legacyId == null && (json['id'] is! String || json['updates'] is! Map)) {
      throw const FormatException('Invalid v2 saved title');
    }
    final raw = json['entries'] as Map;
    final progress = (json['progress'] as List? ?? []).map((p) =>
      ReadingProgress.fromJson(Map<String, dynamic>.from(p as Map))).toList();
    final lastChapter = json['lastChapter'] as String? ?? '';
    final lastSource = json['lastSource'] as String? ?? '';
    // Preserve the original label even if its coordinates cannot be recovered.
    if (legacyId != null && lastChapter.isNotEmpty) {
      progress.add(ReadingProgress(source: lastSource,
        chapter: Chapter(id: '', name: lastChapter)));
    }
    return SavedBook(
      id: legacyId ?? json['id'] as String?,
      title: json['title'] as String,
      requiresLinkApproval: json['requiresLinkApproval'] == true,
      entries: raw.map((k, v) => MapEntry(k.toString(),
        MangaEntry.fromJson(Map<String, dynamic>.from(v as Map)))),
      lastChapter: lastChapter, lastSource: lastSource, progress: progress,
      updates: json['updates'] is Map ? ChapterUpdateState.fromJson(
        Map<String, dynamic>.from(json['updates'] as Map)) : null);
  }
}

class LibraryStore extends ChangeNotifier {
  static const legacyStorageKey = 'senreader.library.v1';
  static const storageKey = 'senreader.library.v2';
  Map<String, SavedBook> _books = {};
  Future<void> _pending = Future.value();
  String? loadError;
  List<SavedBook> get items => _books.values.toList();

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = prefs.getString(storageKey);
      final legacy = prefs.getString(legacyStorageKey);
      final List raw;
      if (current != null) {
        final document = jsonDecode(current) as Map;
        if (document['version'] != 2) throw const FormatException('Unknown library version');
        raw = document['books'] as List;
      } else {
        raw = legacy == null ? [] : jsonDecode(legacy) as List;
      }
      final books = <String, SavedBook>{};
      for (var i = 0; i < raw.length; i++) {
        final book = SavedBook.fromJson(Map<String, dynamic>.from(raw[i] as Map),
          legacyId: current == null ? 'legacy:$i' : null);
        if (book.entries.isEmpty || books.containsKey(book.id)) {
          throw const FormatException('Invalid saved title');
        }
        books[book.id] = book;
      }
      // Commit migration only after a complete parse. Retain v1 unchanged as backup.
      if (current == null && legacy != null) await _write(prefs, books);
      _books = books;
      loadError = null;
    } catch (e) {
      loadError = 'Библиотека не загружена; исходные данные сохранены: $e';
    }
    notifyListeners();
  }

  SavedBook? _find(UnifiedManga book, Map<String, SavedBook> books) {
    if (book.savedId != null && books.containsKey(book.savedId)) return books[book.savedId];
    final matches = books.values.where((saved) => book.entries.values.any((entry) =>
      saved.entries[entry.source]?.id == entry.id)).toList();
    if (matches.length > 1) throw StateError('Подтвердите объединение сохранённых тайтлов вручную.');
    if (matches.isNotEmpty) return matches.single;
    if (book.requiresLinkApproval) return null;
    final exact = books.values.where((saved) =>
      normalizedTitle(saved.title).isNotEmpty &&
      normalizedTitle(saved.title) == normalizedTitle(book.title)).toList();
    if (exact.length != 1) return null;
    final candidate = exact.single;
    if (candidate.requiresLinkApproval) return null;
    if (book.entries.values.any((entry) => candidate.entries.containsKey(entry.source) &&
      candidate.entries[entry.source]!.id != entry.id)) return null;
    return candidate;
  }

  bool has(UnifiedManga book) => get(book) != null;
  SavedBook? get(UnifiedManga book) {
    try { return _find(book, _books); }
    on StateError { return null; }
  }

  Future<void> _write(SharedPreferences prefs, Map<String, SavedBook> books) async {
    final success = await prefs.setString(storageKey, jsonEncode({
      'version': 2, 'books': books.values.map((e) => e.toJson()).toList()}));
    if (!success) throw StateError('Не удалось сохранить библиотеку');
  }

  // Serialize checks and edits; publish state only after durable storage succeeds.
  Future<T> _edit<T>(Future<T> Function(Map<String, SavedBook>) action) {
    final operation = _pending.then((_) async {
      if (loadError != null) throw StateError(loadError!);
      final next = _books.map((k, v) => MapEntry(k, SavedBook.fromJson(v.toJson())));
      final result = await action(next);
      await _write(await SharedPreferences.getInstance(), next);
      _books = next;
      notifyListeners();
      return result;
    });
    _pending = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  void _addEntries(SavedBook saved, UnifiedManga book, {bool approved = false}) {
    for (final entry in book.entries.values) {
      final existing = saved.entries[entry.source];
      if (existing == null && !approved && (saved.requiresLinkApproval || book.requiresLinkApproval)) {
        throw StateError('Подтвердите неоднозначную связь вручную.');
      }
      if (existing != null && existing.id != entry.id) {
        throw StateError('Неоднозначная связь: два тайтла одного источника.');
      }
      saved.entries[entry.source] = entry;
    }
    saved.requiresLinkApproval = saved.requiresLinkApproval || book.requiresLinkApproval;
  }

  SavedBook _add(UnifiedManga book, Map<String, SavedBook> books) {
    final current = _find(book, books);
    final otherOwners = books.values.where((saved) => saved.id != current?.id &&
      book.entries.values.any((entry) => saved.entries[entry.source]?.id == entry.id));
    if (otherOwners.isNotEmpty) {
      throw StateError('Подтвердите связь с другим сохранённым тайтлом вручную.');
    }
    if (current != null) {
      _addEntries(current, book);
      return current;
    }
    final saved = SavedBook(title: book.title, entries: {...book.entries},
      requiresLinkApproval: book.requiresLinkApproval);
    books[saved.id] = saved;
    return saved;
  }

  Future<void> add(UnifiedManga book) => _edit((books) async { _add(book, books); });
  Future<void> remove(UnifiedManga book) => _edit((books) async {
    final saved = _find(book, books);
    if (saved != null) books.remove(saved.id);
  });

  /// Only an explicit UI confirmation may link differently named titles.
  Future<void> connect(UnifiedManga target, UnifiedManga candidate,
      {required bool approved}) => _edit((books) async {
    if (!approved) throw StateError('Требуется подтверждение связи');
    final saved = _add(target, books);
    final other = _find(candidate, books);
    _addEntries(saved, candidate, approved: true);
    if (other == null || other.id == saved.id) return;
    _addEntries(saved, other.toUnified(), approved: true);
    saved.progress.addAll(other.progress);
    if (saved.lastChapter.isEmpty) {
      saved.lastChapter = other.lastChapter;
      saved.lastSource = other.lastSource;
    }
    final inbox = {...saved.updates.inbox};
    for (final entry in other.updates.inbox.entries) {
      final existing = inbox[entry.key];
      final otherTime = entry.value.detectedAtMicros;
      final existingTime = existing?.detectedAtMicros;
      if (existing == null || (otherTime != null && existingTime != null && otherTime < existingTime)) {
        inbox[entry.key] = entry.value;
      }
    }
    saved.updates = ChapterUpdateState(
      initialized: saved.updates.initialized || other.updates.initialized,
      seen: {...saved.updates.seen, ...other.updates.seen},
      notified: {...saved.updates.notified, ...other.updates.notified},
      inbox: inbox);
    books.remove(other.id);
  });

  Future<void> markRead(UnifiedManga book, Chapter chapter, String source) => _edit((books) async {
    final item = _add(book, books);
    item.lastChapter = chapter.name;
    item.lastSource = source;
    item.progress.add(ReadingProgress(source: source, chapter: chapter));
    final key = canonicalChapterKey(chapter);
    final inbox = {...item.updates.inbox}..remove(key);
    item.updates = ChapterUpdateState(initialized: item.updates.initialized,
      seen: {...item.updates.seen, if (key != null) key},
      notified: item.updates.notified, inbox: inbox);
  });

  Future<ChapterCheckResult> check(String id, ChapterChecker checker) => _edit((books) async {
    final saved = books[id];
    if (saved == null) throw StateError('Тайтл удалён из библиотеки');
    final result = await checker.check(saved.entries, saved.updates);
    saved.updates = result.state;
    return result;
  });
}
