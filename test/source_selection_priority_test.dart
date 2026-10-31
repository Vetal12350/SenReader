import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/catalog_repository.dart';

class _ChapterCountSource implements MangaSource {
  _ChapterCountSource(this.key, this.count);
  @override final String key;
  final int count;
  @override String get name => key;
  @override Map<String, String> get imageHeaders => const {};
  @override Future<List<MangaEntry>> popular() async => [];
  @override Future<List<MangaEntry>> search(String query) async => [];
  @override Future<MangaDetail> detail(MangaEntry entry) async => MangaDetail(
    entry: entry, chapters: [
      for (var index = 1; index <= count; index++)
        Chapter(id: '$index', name: 'Глава $index'),
    ]);
  @override Future<List<PageImage>> pages(Chapter chapter) async => [];
}

void main() {
  final book = UnifiedManga(title: 'Series', entries: {
    'senkuro': const MangaEntry(source: 'senkuro', id: 'a', title: 'Series'),
    'readmanga': const MangaEntry(source: 'readmanga', id: 'b', title: 'Series'),
    'remanga': const MangaEntry(source: 'remanga', id: 'c', title: 'Series'),
  });
  test('new title prefers source with the largest confirmed chapter count', () async {
    final repo = CatalogRepository(sources: {
      'senkuro': _ChapterCountSource('senkuro', 10),
      'readmanga': _ChapterCountSource('readmanga', 50),
      'remanga': _ChapterCountSource('remanga', 25),
    });
    expect(await repo.mostCompleteSource(book, 'senkuro'), 'readmanga');
  });
  test('equal chapter counts retain existing source', () async {
    final repo = CatalogRepository(sources: {
      'senkuro': _ChapterCountSource('senkuro', 30),
      'readmanga': _ChapterCountSource('readmanga', 30),
      'remanga': _ChapterCountSource('remanga', 0),
    });
    expect(await repo.mostCompleteSource(book, 'senkuro'), 'senkuro');
  });
}
