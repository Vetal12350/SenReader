import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/page_load_retry.dart';

class _FlakyPageSource implements MangaSource {
  _FlakyPageSource(this.answers);
  final List<Object> answers;
  int requests = 0;
  @override String get key => 'senkuro';
  @override String get name => 'Senkuro';
  @override Map<String, String> get imageHeaders => const {};
  @override Future<List<MangaEntry>> popular() async => [];
  @override Future<List<MangaEntry>> search(String query) async => [];
  @override Future<MangaDetail> detail(MangaEntry entry) async =>
      MangaDetail(entry: entry, chapters: []);
  @override Future<List<PageImage>> pages(Chapter chapter) async {
    final answer = answers[requests < answers.length ? requests : answers.length - 1];
    requests++;
    if (answer is Exception) throw answer;
    return answer as List<PageImage>;
  }
}

void main() {
  const chapter = Chapter(id: '42', name: 'Глава 42');
  const noWait = [Duration.zero, Duration.zero];

  test('retries 503 and transient CDN timeout, keeps the successful pages', () async {
    final source = _FlakyPageSource([
      SourceException('Senkuro: HTTP 503'),
      SourceException('Нет соединения или время ожидания истекло'),
      [const PageImage('https://example.com/image.png')],
    ]);
    final pages = await loadChapterPagesWithRetry(source, chapter, backoffs: noWait);
    expect(source.requests, 3);
    expect(pages.single.url, 'https://example.com/image.png');
  });

  test('temporary empty pages are rechecked before showing an empty chapter', () async {
    final source = _FlakyPageSource([
      <PageImage>[],
      [const PageImage('https://example.com/42.png')],
    ]);
    final pages = await loadChapterPagesWithRetry(source, chapter, backoffs: noWait);
    expect(source.requests, 2);
    expect(pages.length, 1);
  });

  test('access-restricted pages do not cause repeated requests', () async {
    for (final reason in [
      'ReManga: глава недоступна без авторизации или оплаты.',
      'Senkuro: HTTP 403',
      'ReadManga: HTTP 404',
    ]) {
      final source = _FlakyPageSource([SourceException(reason)]);
      await expectLater(
        loadChapterPagesWithRetry(source, chapter, backoffs: noWait),
        throwsA(isA<SourceException>()));
      expect(source.requests, 1);
    }
  });

  test('bounded retry eventually returns the last transient failure', () async {
    final source = _FlakyPageSource([SourceException('HTTP 502')]);
    await expectLater(
      loadChapterPagesWithRetry(source, chapter, backoffs: noWait),
      throwsA(isA<SourceException>()));
    expect(source.requests, 3);
  });
}
