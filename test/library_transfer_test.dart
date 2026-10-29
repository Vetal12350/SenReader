import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/data/library_transfer.dart';

Map<String, dynamic> row({String title = 'Example', String id = 'example'}) => {
      'title': title,
      'entries': {
        'senkuro': {'source': 'senkuro', 'id': id, 'title': title, 'coverUrl': ''},
      },
      'lastChapter': 'Chapter 12',
      'lastSource': 'senkuro',
      'seenChapterKeys': ['v0:c12'],
      'initializedSources': ['senkuro'],
    };

String backup(List<dynamic> books) => jsonEncode({
      'format': LibraryTransfer.format,
      'version': 1,
      'books': books,
    });

void main() {
  const transfer = LibraryTransfer();

  test('SavedBook export round-trips every current field without mutation', () {
    final book = SavedBook(
      title: 'Example',
      entries: {
        'senkuro': const MangaEntry(source: 'senkuro', id: 'example', title: 'Example'),
      },
      lastChapter: 'Chapter 12',
      lastSource: 'senkuro',
      seenChapterKeys: {'v0:c12'},
      initializedSources: {'senkuro'},
    );
    final before = book.toJson();
    final parsed = transfer.parseBytes(utf8.encode(transfer.exportBooks([book])));
    expect(parsed.books.single.toJson(), before);
    expect(book.toJson(), before);
    expect(transfer.preview(parsed).newCount, 1);
  });

  test('early v1 records with no optional state are supported', () {
    final legacy = row()..removeWhere((key, _) =>
        ['lastChapter', 'lastSource', 'seenChapterKeys', 'initializedSources'].contains(key));
    expect(transfer.parse(backup([legacy])).books.single.toJson(), legacy);
  });

  test('unknown fields survive at every level, including newer progress', () {
    final book = row()
      ..['completedChapterKeys'] = ['v0:c1', 'v0:c12']
      ..['resume'] = {'chapter': '12', 'page': 8}
      ..['status'] = 'completed';
    (book['entries'] as Map)['senkuro']['futureEntry'] = {'value': true};
    final envelope = jsonDecode(backup([book])) as Map<String, dynamic>;
    envelope['futureEnvelope'] = {'revision': 7};
    final parsed = transfer.parse(jsonEncode(envelope));
    final copy = parsed.books.single.toJson();
    copy['resume']['page'] = 0;
    expect(jsonDecode(parsed.toJsonString()), envelope);
    expect(parsed.books.single.toJson(), book);
    expect(transfer.parse(parsed.toJsonString()).books.single.toJson(), book);
  });

  test('valid multi-source entries and exact trusted cover hosts', () {
    final book = row();
    (book['entries'] as Map).addAll({
      'readmanga': {
        'source': 'readmanga', 'id': 'https://a.zazaza.me/example',
        'title': 'Another translated title', 'coverUrl': 'https://a.zazaza.me/cover.jpg',
      },
      'remanga': {
        'source': 'remanga', 'id': 'example_2', 'title': 'Example',
        'coverUrl': 'https://remanga.org/cover.jpg',
      },
    });
    expect(transfer.parse(backup([book])).books.single.sourceIds.length, 3);
    (book['entries'] as Map)['readmanga']['id'] = '/example';
    expect(transfer.parse(backup([book])).books.length, 1);
  });

  test('rejects malformed, corrupt, wrong format/version and invalid UTF8', () {
    for (final text in [
      '', '{', '[]', 'null', '{}', '{"books":[]}',
      backup([]).replaceFirst('senreader-library', 'senkuro'),
      backup([]).replaceFirst('"version":1', '"version":2'),
      backup([]).replaceFirst('"version":1', '"version":1.0'),
      '${backup([])} trailing', '{"format":"senreader-library",}',
    ]) {
      expect(() => transfer.parse(text), throwsFormatException, reason: text);
    }
    expect(() => transfer.parseBytes([0xff]), throwsFormatException);
  });

  test('bounds bytes, depth and book count before exposing a backup', () {
    expect(() => transfer.parse(' ' * (LibraryTransfer.maxBytes + 1)), throwsFormatException);
    expect(() => transfer.parseBytes(List.filled(LibraryTransfer.maxBytes + 1, 32)),
        throwsFormatException);
    expect(() => transfer.parse('я' * (LibraryTransfer.maxBytes ~/ 2 + 1)),
        throwsFormatException);
    expect(() => transfer.parse('${'[' * 34}0${']' * 34}'), throwsFormatException);
    expect(() => transfer.parse(backup(List.filled(LibraryTransfer.maxBooks + 1, row()))),
        throwsFormatException);
  });

  test('rejects duplicate object keys including escaped spellings', () {
    for (final text in [
      '{"format":"bad",${backup([]).substring(1)}',
      backup([row()]).replaceFirst('"id":"example"', '"id":"a","id":"b"'),
      backup([row()]).replaceFirst('"id":"example"', r'"id":"a","\u0069d":"b"'),
    ]) {
      expect(() => transfer.parse(text), throwsFormatException);
    }
  });

  test('rejects invalid entries, source keys, state and set collisions', () {
    final invalid = <Map<String, dynamic>>[
      row()..['title'] = '!!!', row()..['entries'] = {},
      row()..['lastChapter'] = 12, row()..['lastSource'] = 'unknown',
      row()..['seenChapterKeys'] = ['v0:c1', 'v0:c1'],
      row()..['seenChapterKeys'] = [1],
      row()..['seenChapterKeys'] = ['x' * 129],
      row()..['initializedSources'] = ['unknown'],
      row()..['entries'] = {'unknown': {'source': 'unknown', 'id': 'a', 'title': 'A'}},
      row()..['entries'] = {'senkuro': {'source': 'remanga', 'id': 'a', 'title': 'A'}},
      row()..['entries'] = {'senkuro': {'source': 'senkuro', 'id': '../a', 'title': 'A'}},
      row()..['entries'] = {'senkuro': {'source': 'senkuro', 'id': 'a', 'title': 5}},
    ];
    for (final book in invalid) {
      expect(() => transfer.parse(backup([book])), throwsFormatException);
    }
  });

  test('rejects untrusted URLs and credentials without any network calls', () {
    for (final url in [
      'http://a.zazaza.me/example', 'https://evil.example/example',
      'https://a.zazaza.me.evil.example/example', '//evil.example/example',
      'https://user:password@a.zazaza.me/example', 'https://127.0.0.1/example',
      'https://a.zazaza.me:443/example', 'https://a.zazaza.me/example?token=secret',
      'https://a.zazaza.me/example#fragment', 'https://a.zazaza.me/%2e%2e/a',
      '/example/chapter/1', '//evil.example', 'https://[bad',
    ]) {
      final book = row()..['entries'] = {
        'readmanga': {'source': 'readmanga', 'id': url, 'title': 'Example'},
      };
      book['lastSource'] = 'readmanga';
      book['initializedSources'] = ['readmanga'];
      expect(() => transfer.parse(backup([book])), throwsFormatException, reason: url);
    }
    final book = row();
    book['entries']['senkuro']['coverUrl'] = 'https://cdn.example/a.jpg';
    expect(() => transfer.parse(backup([book])), throwsFormatException);
    const policy = LibraryTransfer(trustedCoverHosts: {'cdn.example'});
    expect(policy.parse(backup([book])).books.length, 1);
  });

  test('counts new, identical local, duplicate and conflicting records accurately', () {
    final local = transfer.parse(backup([row()]));
    final imported = transfer.parse(backup([
      row(), row(), row(title: 'New', id: 'new'),
      row(title: 'EXAMPLE!', id: 'different'),
    ]));
    final result = transfer.preview(imported, existing: local.books);
    // The whole colliding group requires confirmation, including identical rows.
    expect(result.newCount, 1);
    expect(result.conflictCount, 3);
    expect(result.items.first.candidateKeys, ['example']);
    final repeated = transfer.preview(transfer.parse(backup([
      row(), row(), row(title: 'New', id: 'new'), row(title: 'New', id: 'new'),
    ])), existing: local.books);
    expect(repeated.newCount, 1);
    expect(repeated.existingCount, 1);
    expect(repeated.duplicateCount, 2);
    expect(repeated.conflictCount, 0);
    expect(repeated.additions.single.title, 'New');
  });

  test('within-import collisions are order independent and never safe additions', () {
    final a = row();
    final b = row(title: 'EXAMPLE!', id: 'other');
    for (final rows in [[a, b], [b, a]]) {
      final preview = transfer.preview(transfer.parse(backup(rows)));
      expect(preview.conflictCount, 2);
      expect(preview.additions, isEmpty);
    }
  });

  test('translated title with shared source ID is ambiguous; no fuzzy matching', () {
    final local = transfer.parse(backup([row()]));
    final preview = transfer.preview(transfer.parse(backup([
      row(title: 'Translated name'), row(title: 'Example 2', id: 'example2'),
    ])), existing: local.books);
    expect(preview.conflictCount, 1);
    expect(preview.items.first.candidateKeys, ['example']);
    expect(preview.newCount, 1);
  });

  test('preserves all existing progress, markers, entries and baselines', () {
    final current = row()
      ..['completedChapterKeys'] = ['v0:c12']
      ..['pagePosition'] = {'chapter': '12', 'page': 10}
      ..['status'] = 'completed';
    final local = transfer.parse(backup([current]));
    final before = local.toJsonString();
    for (final chapter in ['Chapter 1', 'Chapter 99']) {
      final imported = row()..['lastChapter'] = chapter;
      final preview = transfer.preview(transfer.parse(backup([imported])), existing: local.books);
      expect(preview.conflictCount, 1);
      expect(preview.additions, isEmpty);
      expect(local.toJsonString(), before);
      expect(local.books.single.toJson(), current);
    }
  });

  test('same title with additional or disjoint sources needs confirmation', () {
    final local = transfer.parse(backup([row()]));
    final incoming = row()..['entries'] = {
      'remanga': {'source': 'remanga', 'id': 'example', 'title': 'Example'},
    };
    incoming['lastSource'] = 'remanga';
    incoming['initializedSources'] = ['remanga'];
    expect(transfer.preview(transfer.parse(backup([incoming])), existing: local.books)
        .conflictCount, 1);
  });

  test('JSON map order does not create false conflicts', () {
    final local = transfer.parse(backup([row()]));
    final reversed = Map<String, dynamic>.fromEntries(row().entries.toList().reversed);
    expect(transfer.preview(transfer.parse(backup([reversed])), existing: local.books)
        .existingCount, 1);
  });

  test('legacy ReadManga URLs and relative IDs surface translated ambiguity', () {
    Map<String, dynamic> readmanga(String title, String id) => {
      'title': title,
      'entries': {'readmanga': {'source': 'readmanga', 'id': id, 'title': title}},
    };
    final local = transfer.parse(backup([
      readmanga('Original', 'https://3.readmanga.ru/example'),
    ]));
    for (final id in ['/example', 'https://a.zazaza.me/example']) {
      final imported = transfer.parse(backup([readmanga('Translated', id)]));
      expect(transfer.preview(imported, existing: local.books).conflictCount, 1);
    }
  });

  test('different numeric/string progress in opaque fields is never overwritten', () {
    final local = transfer.parse(backup([row()..['page'] = 9]));
    final imported = transfer.parse(backup([row()..['page'] = '9']));
    expect(transfer.preview(imported, existing: local.books).conflictCount, 1);
  });
}
