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
    required this.createdAt, this.hiddenAt = 0, this.sourceId = '',
  });
  final String key, bookKey, title, coverUrl, source, chapterId, chapterName;
  final int createdAt, hiddenAt;
  final String sourceId;
  bool get hidden => hiddenAt > 0;
  InboxEntry hide(int at) => InboxEntry(key: key, bookKey: bookKey,
    title: title, coverUrl: coverUrl, source: source,
    chapterId: chapterId, chapterName: chapterName,
    createdAt: createdAt, hiddenAt: at, sourceId: sourceId);
  Map<String, Object> toJson() => {
    'key': key, 'bookKey': bookKey, 'title': title, 'coverUrl': coverUrl,
    'source': source, 'chapterId': chapterId, 'chapterName': chapterName,
    'createdAt': createdAt, 'hiddenAt': hiddenAt,
    if (sourceId.isNotEmpty) 'sourceId': sourceId,
  };
  factory InboxEntry.fromJson(Map<String, dynamic> json) => InboxEntry(
    key: json['key'] as String? ?? '', bookKey: json['bookKey'] as String? ?? '',
    title: json['title'] as String? ?? '', coverUrl: json['coverUrl'] as String? ?? '',
    source: json['source'] as String? ?? '',
    chapterId: json['chapterId'] as String? ?? '',
    chapterName: json['chapterName'] as String? ?? '',
    createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
    hiddenAt: (json['hiddenAt'] as num?)?.toInt() ?? 0,
    sourceId: json['sourceId'] as String? ?? '',
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
    final db = await openDatabase(path, version: 4, onCreate: (db, _) async {
      await db.execute('CREATE TABLE inbox (profile TEXT NOT NULL, '
          'identity TEXT NOT NULL, payload TEXT NOT NULL, '
          'systemClaimed INTEGER NOT NULL DEFAULT 0, '
          'systemLease INTEGER NOT NULL DEFAULT 0, systemToken INTEGER NOT NULL DEFAULT 0, '
          'systemQueuedAt INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(profile, identity))');
      await db.execute('CREATE TABLE migration (id TEXT PRIMARY KEY)');
      await db.execute('CREATE INDEX IF NOT EXISTS pending_os ON inbox(profile, systemClaimed, systemQueuedAt, systemLease)');
      await _createScanState(db);
    }, onUpgrade: (db, oldVersion, _) async {
      if (oldVersion < 2) await _createScanState(db);
      if (oldVersion < 3) {
        await db.execute('ALTER TABLE inbox ADD COLUMN systemLease INTEGER NOT NULL DEFAULT 0');
        await db.execute('ALTER TABLE inbox ADD COLUMN systemToken INTEGER NOT NULL DEFAULT 0');
      }
      if (oldVersion < 4) {
        final columns = (await db.rawQuery('PRAGMA table_info(inbox)'))
            .map((c) => c['name']).toSet();
        // Accept either draft v3 shape without applying competing migrations.
        for (final name in ['systemLease', 'systemToken', 'systemQueuedAt']) {
          if (!columns.contains(name)) {
            await db.execute('ALTER TABLE inbox ADD COLUMN $name INTEGER NOT NULL DEFAULT 0');
          }
        }
        await db.execute('CREATE INDEX IF NOT EXISTS pending_os ON inbox(profile, systemClaimed, systemQueuedAt, systemLease)');
      }
    });
    // Once migrated, avoid decoding the entire legacy JSON for every
    // inbox load/insert. The old preference itself remains untouched.
    if ((await db.query('migration', where: 'id = ?',
        whereArgs: ['legacy-v1'])).isNotEmpty) return db;
    // Old global entries have no provable account owner. Preserve the raw
    // preference, import only into the guest namespace, never into a UID.
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(key);
    // A corrupt legacy preference must never prevent a fresh SQLite inbox
    // from working for guest or authenticated profiles. Preserve the original
    // value untouched so it can still be recovered from a backup.
    if (raw != null && raw.length <= 1000000) {
      List<dynamic>? legacy;
      try {
        final value = jsonDecode(raw);
        if (value is List) legacy = value;
      } on FormatException {
        // Old v1 data is malformed; keep using the new inbox normally.
      }
      if (legacy != null) {
        await db.transaction((txn) async {
          if ((await txn.query('migration', where: 'id = ?',
              whereArgs: ['legacy-v1'])).isNotEmpty) return;
          for (final value in legacy!.whereType<Map>()) {
            try {
              final entry = InboxEntry.fromJson(
                  Map<String, dynamic>.from(value));
              if (entry.bookKey.isEmpty || entry.key.isEmpty) continue;
              await _insert(txn, '', entry, claimed: 1);
            } on TypeError {
              // Skip only the invalid row, preserving valid legacy updates.
            } on FormatException {
              // A bad legacy row must not block the entire inbox.
            }
          }
          await txn.insert('migration', {'id': 'legacy-v1'});
        });
      }
    }
    return db;
  }

  static Future<void> _createScanState(Database db) => db.execute(
      'CREATE TABLE scan_state (profile TEXT NOT NULL, book TEXT NOT NULL, '
      'source TEXT NOT NULL, sourceId TEXT NOT NULL, payload TEXT NOT NULL, '
      'PRIMARY KEY(profile, book, source, sourceId))');

  /// Scan metadata must never rewrite the SharedPreferences library blob:
  /// a background isolate could otherwise overwrite a concurrent page save.
  Future<void> recordScan(String book, String source, String sourceId,
      Iterable<String> keys, Map<String, DateTime> dates) async {
    final profile = await _profile();
    final db = await _database();
    await db.transaction((txn) async {
      final rows = await txn.query('scan_state',
          where: 'profile = ? AND book = ? AND source = ? AND sourceId = ?',
          whereArgs: [profile, book, source, sourceId]);
      final previous = rows.isEmpty ? <String, dynamic>{} :
          jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
      final seen = <String>{...List<String>.from(previous['seen'] ?? []), ...keys};
      final times = Map<String, int>.from(previous['dates'] ?? {});
      for (final entry in dates.entries) {
        if (entry.value.year >= 2000) {
          times[entry.key] = entry.value.toUtc().millisecondsSinceEpoch;
        }
      }
      await txn.insert('scan_state', {
        'profile': profile, 'book': book, 'source': source, 'sourceId': sourceId,
        'payload': jsonEncode({'seen': seen.toList(), 'dates': times}),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<List<Map<String, Object?>>> loadScanState() async {
    final profile = await _profile();
    return (await _database()).query('scan_state',
        where: 'profile = ?', whereArgs: [profile]);
  }

  static String _identity(InboxEntry entry) => entry.bookKey + '|' +
      (canonicalChapterKey(Chapter(id: entry.chapterId, name: entry.chapterName))
          ?? '${entry.source}|id:${entry.chapterId}');

  static Future<void> _insert(DatabaseExecutor db, String profile,
      InboxEntry entry, {int claimed = 0, bool systemPending = false}) async {
    await db.insert('inbox', {'profile': profile, 'identity': _identity(entry),
      'payload': jsonEncode(entry.toJson()), 'systemClaimed': claimed,
      'systemQueuedAt': systemPending ? DateTime.now().millisecondsSinceEpoch : 0},
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
      String source, Chapter chapter,
      {bool systemPending = false, String sourceId = ''}) async {
    final profile = await _profile();
    final db = await _database();
    final entry = InboxEntry(key: '$bookKey|${sourceChapterKey(chapter, source)}',
      bookKey: bookKey, title: title, coverUrl: coverUrl, source: source,
      chapterId: chapter.id, chapterName: chapter.name, sourceId: sourceId,
      createdAt: DateTime.now().millisecondsSinceEpoch);
    await _insert(db, profile, entry, systemPending: systemPending);
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

  Future<List<InboxEntry>> pendingSystemNotifications({int limit = 10}) async {
    final profile = await _profile();
    final rows = await (await _database()).query('inbox', where:
      'profile = ? AND systemClaimed = 0 AND systemQueuedAt > 0 AND systemLease <= ?',
      whereArgs: [profile, DateTime.now().millisecondsSinceEpoch],
      orderBy: 'systemQueuedAt, identity', limit: limit.clamp(1, 10).toInt());
    return rows.map((r) => InboxEntry.fromJson(jsonDecode(r['payload'] as String)
      as Map<String, dynamic>)).toList();
  }
  Future<void> retireSystemDelivery(InboxEntry entry) async {
    final profile = await _profile();
    await (await _database()).update('inbox', {'systemQueuedAt': 0},
      where: 'profile = ? AND identity = ?', whereArgs: [profile, _identity(entry)]);
  }
  Future<void> hideChapter(String book, Chapter chapter, String source) =>
      _change((e) => e.bookKey == book && _identity(e) ==
        '$book|${canonicalChapterKey(chapter) ?? '$source|id:${chapter.id}'}',
        DateTime.now().millisecondsSinceEpoch);

  /// A finite claim survives process death. Acknowledgement follows OS delivery.
  Future<int?> beginSystemDelivery(InboxEntry entry, {int? now}) async {
    final profile = await _profile();
    final db = await _database();
    final at = now ?? DateTime.now().millisecondsSinceEpoch;
    return db.transaction((t) async {
      final rows = await t.query('inbox', where:
        'profile = ? AND identity = ? AND systemClaimed = 0 AND systemQueuedAt > 0 AND systemLease <= ?',
        whereArgs: [profile, _identity(entry), at]);
      if (rows.isEmpty) return null;
      final row = rows.single;
      if (InboxEntry.fromJson(jsonDecode(row['payload'] as String)
          as Map<String, dynamic>).hidden) return null;
      final token = (row['systemToken'] as int) + 1;
      await t.update('inbox', {'systemLease': at + 60000, 'systemToken': token},
        where: 'profile = ? AND identity = ?', whereArgs: [profile, _identity(entry)]);
      return token;
    });
  }
  Future<bool> systemDeliveryCurrent(InboxEntry entry, int token) async {
    final profile = await _profile();
    return (await (await _database()).query('inbox', columns: ['identity'], where:
      'profile = ? AND identity = ? AND systemToken = ? AND systemClaimed = 0 AND systemQueuedAt > 0',
      whereArgs: [profile, _identity(entry), token])).isNotEmpty;
  }
  Future<void> finishSystemDelivery(InboxEntry entry, int token,
      {required bool delivered}) async {
    final profile = await _profile();
    await (await _database()).update('inbox',
      {'systemLease': 0, if (delivered) 'systemClaimed': 1},
      where: 'profile = ? AND identity = ? AND systemToken = ?',
      whereArgs: [profile, _identity(entry), token]);
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
        await txn.update('inbox', {'payload': jsonEncode(entry.hide(at).toJson()),
          if (at > 0) 'systemQueuedAt': 0},
          where: 'profile = ? AND identity = ?',
          whereArgs: [profile, row['identity']]);
      }
    });
  }
  /// Archive/restore a displayed title group atomically without changing
  /// the individual chapter identities or other profile's inbox.
  Future<void> setEntriesHidden(Iterable<String> identities,
      {required bool hidden}) async {
    final keys = identities.toSet();
    if (keys.isEmpty) return;
    await _change((entry) => keys.contains(entry.key) &&
        entry.hidden != hidden,
        hidden ? DateTime.now().millisecondsSinceEpoch : 0);
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

