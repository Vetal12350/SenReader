import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/title_matching.dart';

void main() {
  test('same title from Senkuro and ReadManga merges into one entry', () {
    final books = mergeEntries([
      const MangaEntry(source: 'readmanga', id: '/abc', title: 'Тест: манхва!'),
      const MangaEntry(source: 'senkuro', id: 'slug', title: 'Тест Манхва'),
    ]);
    expect(books.length, 1);
    expect(books.single.primary.source, 'senkuro');
    expect(books.single.entries.length, 2);
  });
  test('unrelated similar names are not merged', () {
    final books = mergeEntries([
      const MangaEntry(source: 'senkuro', id: 'a', title: 'Хроники 1'),
      const MangaEntry(source: 'readmanga', id: 'b', title: 'Хроники 2'),
    ]);
    expect(books.length, 2);
  });
}
