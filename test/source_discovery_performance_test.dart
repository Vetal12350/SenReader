import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/catalog_repository.dart';

class _SearchGateSource implements MangaSource {
  _SearchGateSource(this.key, this.response);
  @override final String key;
  @override String get name => key;
  @override Map<String, String> get imageHeaders => const {};
  final Future<List<MangaEntry>> response;
  int searches = 0;

  @override Future<List<MangaEntry>> search(String query) {
    searches++;
    return response;
  }

  @override Future<List<MangaEntry>> popular() async => [];
  @override Future<MangaDetail> detail(MangaEntry entry) async =>
      MangaDetail(entry: entry, chapters: []);
  @override Future<List<PageImage>> pages(Chapter chapter) async => [];
}

void main() {
  test('source discovery starts every provider without waiting for slower one',
      () async {
    const title = 'Путешествие героя';
    final slowGate = Completer<List<MangaEntry>>();
    final slow = _SearchGateSource('readmanga', slowGate.future);
    final fast = _SearchGateSource('remanga', Future.value([
      const MangaEntry(source: 'remanga', id: 'fast',
        title: 'ПУТЕШЕСТВИЕ ГЕРОЯ!'),
      const MangaEntry(source: 'remanga', id: 'not-match',
        title: 'Путешествие героя: продолжение'),
    ]));
    final existing = const MangaEntry(source: 'senkuro', id: 'original',
      title: title);
    final repo = CatalogRepository(sources: {
      'senkuro': _SearchGateSource('senkuro', Future.value([])),
      'readmanga': slow,
      'remanga': fast,
    });
    final book = UnifiedManga(title: title,
      entries: {'senkuro': existing});

    final resultFuture = repo.findOtherSources(book);
    await Future<void>.delayed(Duration.zero);
    // Before the slow source resolves, the next provider must have started.
    expect(slow.searches, 1);
    expect(fast.searches, 1);
    slowGate.complete([
      const MangaEntry(source: 'readmanga', id: 'slow', title: title),
    ]);
    final result = await resultFuture;
    expect(result.entries.keys.toList(),
      ['senkuro', 'readmanga', 'remanga']);
    expect(result.entries['readmanga']?.id, 'slow');
    expect(result.entries['remanga']?.id, 'fast');
    expect(result.entries['senkuro']?.id, 'original');
  });

  test('unavailable secondary source cannot remove or rewrite original',
      () async {
    const original = MangaEntry(source: 'senkuro', id: 'original',
      title: 'Оригинал');
    final repo = CatalogRepository(sources: {
      'senkuro': _SearchGateSource('senkuro', Future.value([])),
      'remanga': _SearchGateSource('remanga',
        Future.error(SourceException('HTTP 503'))),
      'readmanga': _SearchGateSource('readmanga',
        Future.value([const MangaEntry(source: 'readmanga',
          id: 'sequel', title: 'Оригинал 2')])),
    });
    final book = UnifiedManga(title: original.title,
      entries: {'senkuro': original});
    final result = await repo.findOtherSources(book);
    expect(result.entries.keys, ['senkuro']);
    expect(result.entries['senkuro'], original);
  });
}
