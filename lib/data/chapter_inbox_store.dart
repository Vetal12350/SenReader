import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
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
  ChapterInboxStore({this.profileId});
  final String? profileId;
  static const key = 'senreader.chapter_inbox.v1';
  static const hiddenLimit = 50;
  static String? databasePathOverride;

  Future<String> _profile() async {
    if (profileId != null) return profileId!;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getString('senreader.active.profile.v1') ?? '';
  }

  Future<Database> _database() async {
    final path = databasePathOverride ??
        '${await getDatabasesPath()}/senreader_chapter_inbox_v2.db';
    final db = await openDatabase(path, version: 1, onCreate: (db, _) async {
      await db.execute('CREATE TABLE inbox (profile TEXT NOT NULL, '
          'identity TEXT NOT NULL, payload TEXT NOT NULL, '
          'systemClaimed INTEGER NOT NULL DEFAULT 0, '
          'PRIMARY KEY(profile, identity))');
      await db.execute('CREATE TABLE migration (id TEXT PRIMARY KEY)');
    });
    // Old global entries have no provable account owner. Preserve the raw
    // preference, import only into the guest namespace, never into a UID.
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(key);
    if (raw != null) {
      await db.transaction((txn) async {
        if ((await txn.query('migration', where: 'id = ?',
            whereArgs: ['legacy-v1'])).isNotEmpty) return;
        final decoded = jsonDecode(raw);
        if (decoded is! List) throw const FormatException('Invalid legacy inbox');
        for (final value in decoded.whereType<Map>()) {
          final entry = InboxEntry.fromJson(Map<String, dynamic>.from(value));
          if (entry.bookKey.isEmpty || entry.key.isEmpty) continue;
          await _insert(txn, '', entry, claimed: 1);
        }
        await txn.insert('migration', {'id': 'legacy-v1'});
      });
    }
    return db;
  }

  static String _identity(InboxEntry entry) => entry.bookKey + '|' +
      (canonicalChapterKey(Chapter(id: entry.chapterId, name: entry.chapterName))
          ?? '${entry.source}|id:${entry.chapterId}');

  static Future<void> _insert(DatabaseExecutor db, String profile,
      InboxEntry entry, {int claimed = 0}) async {
    await db.insert('inbox', {'profile': profile, 'identity': _identity(entry),
      'payload': jsonEncode(entry.toJson()), 'systemClaimed': claimed},
      conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<InboxEntry>> load() async {
    final profile = await _profile();
    final db = await _database();
    final rows = await db.query('inbox', where: 'profile = ?', whereArgs: [profile]);
    return rows.map((row) => InboxEntry.fromJson(
        jsonDecode(row['payload'] as String) as Map<String, dynamic>)).toList();
  }

  // Retained for old callers/tests. Durable delivery identities are never
  // pruned from SQLite when an entry is hidden.
  static List<InboxEntry> trim(List<InboxEntry> entries) {
    final active = entries.where((e) => !e.hidden).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final hidden = entries.where((e) => e.hidden).toList()
      ..sort((a, b) => b.hiddenAt.compareTo(a.hiddenAt));
    return [...active, ...hidden.take(hiddenLimit)];
  }

  Future<void> add(String bookKey, String title, String coverUrl,
      String source, Chapter chapter) async {
    final profile = await _profile();
    final db = await _database();
    final entry = InboxEntry(key: '$bookKey|${sourceChapterKey(chapter, source)}',
      bookKey: bookKey, title: title, coverUrl: coverUrl, source: source,
      chapterId: chapter.id, chapterName: chapter.name,
      createdAt: DateTime.now().millisecondsSinceEpoch);
    await _insert(db, profile, entry);
  }

  /// At-most-once OS delivery. A crash after claiming may omit an optional
  /// system alert; the mandatory inbox is already committed and unaffected.
  Future<bool> claimSystemNotification(String bookKey, Chapter chapter,
      String source) async {
    final profile = await _profile();
    final db = await _database();
    final identity = '$bookKey|${canonicalChapterKey(chapter) ?? '$source|id:${chapter.id}'}';
    return await db.update('inbox', {'systemClaimed': 1},
      where: 'profile = ? AND identity = ? AND systemClaimed = 0',
      whereArgs: [profile, identity]) == 1;
  }

  Future<void> _change(bool Function(InboxEntry) matches, int at) async {
    final profile = await _profile();
    final db = await _database();
    await db.transaction((txn) async {
      final rows = await txn.query('inbox', where: 'profile = ?', whereArgs: [profile]);
      for (final row in rows) {
        final entry = InboxEntry.fromJson(jsonDecode(row['payload'] as String)
            as Map<String, dynamic>);
        if (!matches(entry)) continue;
        await txn.update('inbox', {'payload': jsonEncode(entry.hide(at).toJson())},
          where: 'profile = ? AND identity = ?',
          whereArgs: [profile, row['identity']]);
      }
    });
  }
  Future<void> hideEntry(String identity) => _change(
      (e) => e.key == identity && !e.hidden, DateTime.now().millisecondsSinceEpoch);
  Future<void> restoreEntry(String identity) => _change((e) => e.key == identity, 0);
  Future<void> hideReadKeys(String bookKey, String source,
      Set<String> scopedReadKeys) => _change((e) => e.bookKey == bookKey &&
        e.source == source && scopedReadKeys.contains(
          e.key.substring(bookKey.length + 1)) && !e.hidden,
        DateTime.now().millisecondsSinceEpoch);
}
