import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/chapter_inbox_store.dart';
import 'package:senreader/data/library_store.dart';
import 'library_backup_file_test.dart' show syntheticBooks;

void main() {
  test('service 369 v4: 2 new groups, 25 hidden groups and all raw delivery/tombstone state survive v5', () async {
    const profile = 'fixture-user';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(LibraryStore.activeProfileKey, profile);
    await prefs.setString('${LibraryStore.storageKey}.user.$profile', jsonEncode(syntheticBooks()));
    await prefs.setString('synthetic.auth', 'fixture-session');
    await prefs.setString('synthetic.theme', 'dark');
    final preferencesBefore = {for (final key in prefs.getKeys()) key: prefs.get(key)};
    final path = ChapterInboxStore.databasePathOverride!;
    await databaseFactory.deleteDatabase(path);
    final before = <Map<String, Object?>>[];
    final db = await openDatabase(path, version: 4, onCreate: (db, _) async {
      await db.execute('CREATE TABLE inbox(profile TEXT NOT NULL, identity TEXT NOT NULL, payload TEXT NOT NULL, '
        'systemClaimed INTEGER DEFAULT 0, systemLease INTEGER DEFAULT 0, '
        'systemToken INTEGER DEFAULT 0, systemQueuedAt INTEGER DEFAULT 0, PRIMARY KEY(profile,identity))');
      await db.execute('CREATE TABLE migration(id TEXT PRIMARY KEY)');
      await db.insert('migration', {'id': 'legacy-v1'});
      await db.execute('CREATE TABLE scan_state(profile TEXT, book TEXT, source TEXT, sourceId TEXT, payload TEXT)');
      await db.insert('scan_state', {'profile': profile, 'book': 'new-0', 'source': 'senkuro', 'sourceId': 'new-0',
        'payload': '{"seen":["v0:c1","id:c1"],"dates":{},"lastCompleteAt":12345}'});
      Future<void> insert(String book, int n, {bool hidden = false, bool deleted = false, bool read = false}) async {
        final entry = InboxEntry(key: '$book|senkuro|v0:c$n', bookKey: book, title: book,
          source: 'senkuro', sourceId: book, chapterId: 'c$n', chapterName: 'Глава $n', coverUrl: '',
          createdAt: 100 + n, hiddenAt: hidden ? 1000 : 0, deletedAt: deleted ? 2000 : 0,
          readAt: read ? 3000 : 0);
        final row = <String,Object?>{'profile': profile, 'identity': '$book|v0:c$n',
          'payload': jsonEncode(entry.toJson()), 'systemClaimed': 1, 'systemLease': n,
          'systemToken': n + 7, 'systemQueuedAt': n * 100};
        await db.insert('inbox', row); before.add(row);
      }
      await insert('new-0', 1); await insert('new-0', 2); await insert('new-1', 1);
      for (var i = 0; i < 25; i++) {
        await insert('hidden-$i', 1, hidden: true); await insert('hidden-$i', 2, hidden: true);
      }
      await insert('deleted', 1, deleted: true); await insert('read', 1, read: true);
    });
    final baselineBefore = await db.query('scan_state');
    await db.close();
    final store = ChapterInboxStore(profileId: profile);
    final entries = await store.load(); // Actual v4 -> v5 migration.
    expect(entries.length, 55);
    expect(entries.where((e) => !e.hidden && !e.read && !e.deleted).map((e) => e.bookKey).toSet().length, 2);
    expect(entries.where((e) => e.hidden).map((e) => e.bookKey).toSet().length, 25);
    expect(entries.where((e) => e.bookKey == 'new-0').map((e) => e.chapterId).toSet(), {'c1', 'c2'});
    final upgraded = await openDatabase(path);
    expect(await upgraded.getVersion(), 5);
    for (final row in await upgraded.query('inbox')) {
      final old = before.singleWhere((r) => r['profile'] == row['profile'] && r['identity'] == row['identity']);
      expect({for (final key in old.keys) key: row[key]}, old);
    }
    expect(await upgraded.query('scan_state'), baselineBefore);
    expect((await upgraded.rawQuery('PRAGMA integrity_check')).single.values.single, 'ok');
    for (final entry in entries) {
      await store.add(entry.bookKey, entry.title, '', entry.source,
        Chapter(id: entry.chapterId, name: entry.chapterName), sourceId: entry.sourceId, systemPending: true);
    }
    expect((await store.load()).length, 55);
    expect(await store.pendingSystemNotifications(limit: null), isEmpty);
    await upgraded.close();
    expect((await ChapterInboxStore(profileId: profile).load()).map((e) => e.toJson()).toList(),
      entries.map((e) => e.toJson()).toList());
    expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, preferencesBefore);
  });
}
