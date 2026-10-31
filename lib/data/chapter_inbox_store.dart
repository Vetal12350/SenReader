import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/models.dart';
import '../core/chapter_identity.dart';

/// Persistent local notifications independent of Android's notification shade.
/// Archive exact chapter identities, never another title's updates.
class InboxEntry {
  const InboxEntry({
    required this.key, required this.bookKey, required this.title,
    required this.coverUrl, required this.source,
    required this.chapterId, required this.chapterName,
    required this.createdAt, this.hiddenAt = 0,
  });
  final String key, bookKey, title, coverUrl, source, chapterId, chapterName;
  final int createdAt, hiddenAt;
  bool get hidden => hiddenAt > 0;
  InboxEntry hide(int at) => InboxEntry(key: key, bookKey: bookKey,
    title: title, coverUrl: coverUrl, source: source,
    chapterId: chapterId, chapterName: chapterName,
    createdAt: createdAt, hiddenAt: at);
  Map<String, Object> toJson() => {
    'key': key, 'bookKey': bookKey, 'title': title, 'coverUrl': coverUrl,
    'source': source, 'chapterId': chapterId, 'chapterName': chapterName,
    'createdAt': createdAt, 'hiddenAt': hiddenAt,
  };
  factory InboxEntry.fromJson(Map<String, dynamic> json) => InboxEntry(
    key: json['key'] as String? ?? '', bookKey: json['bookKey'] as String? ?? '',
    title: json['title'] as String? ?? '', coverUrl: json['coverUrl'] as String? ?? '',
    source: json['source'] as String? ?? '',
    chapterId: json['chapterId'] as String? ?? '',
    chapterName: json['chapterName'] as String? ?? '',
    createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
    hiddenAt: (json['hiddenAt'] as num?)?.toInt() ?? 0,
  );
}

class ChapterInboxStore {
  ChapterInboxStore({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();
  static const key = 'senreader.chapter_inbox.v1';
  static const hiddenLimit = 50;
  final SharedPreferencesAsync _preferences;
  Future<List<InboxEntry>> load() async {
    final raw = await _preferences.getString(key);
    if (raw == null) return [];
    try {
      if (raw.length > 1000000) return [];
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list.take(500).whereType<Map>().map(
        (value) => InboxEntry.fromJson(Map<String, dynamic>.from(value)),
      ).where((entry) => entry.bookKey.isNotEmpty && entry.key.isNotEmpty)
       .toList();
    } catch (_) { return []; }
  }
  static List<InboxEntry> trim(List<InboxEntry> entries) {
    final active = entries.where((e) => !e.hidden).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final hidden = entries.where((e) => e.hidden).toList()
      ..sort((a, b) => b.hiddenAt.compareTo(a.hiddenAt));
    return [...active.take(450), ...hidden.take(hiddenLimit)];
  }
  Future<void> _save(List<InboxEntry> entries) =>
      _preferences.setString(key, jsonEncode(trim(entries)
        .map((entry) => entry.toJson()).toList()));

  Future<void> add(String bookKey, String title, String coverUrl,
      String source, Chapter chapter) async {
    final id = sourceChapterKey(chapter, source);
    final identity = bookKey + '|' + id;
    final entries = await load();
    if (entries.any((e) => e.key == identity)) return;
    entries.add(InboxEntry(key: identity, bookKey: bookKey, title: title,
      coverUrl: coverUrl, source: source, chapterId: chapter.id,
      chapterName: chapter.name,
      createdAt: DateTime.now().millisecondsSinceEpoch));
    await _save(entries);
  }

  Future<void> hideEntry(String identity) async {
    final entries = await load();
    final at = DateTime.now().millisecondsSinceEpoch;
    await _save([for (final e in entries) e.key == identity && !e.hidden
        ? e.hide(at) : e]);
  }

  Future<void> hideReadKeys(String bookKey, String source,
      Set<String> scopedReadKeys) async {
    final entries = await load();
    final at = DateTime.now().millisecondsSinceEpoch;
    await _save([for (final e in entries)
      e.bookKey == bookKey && e.source == source &&
          scopedReadKeys.contains(e.key.substring(bookKey.length + 1)) && !e.hidden
          ? e.hide(at) : e]);
  }
}
