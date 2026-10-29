import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/readmanga_source.dart';

void main() {
  test('catalog tiles parse without network', () {
    final list = ReadMangaSource().parseTiles('''
      <div class="tile"><div class="img"><a class="non-hover" href="/manga/test">
      <img data-original="/covers/a.jpg" title="Пример манхвы" /></a></div></div>
    ''');
    expect(list.length, 1);
    expect(list.first.title, 'Пример манхвы');
    expect(list.first.coverUrl, 'https://3.readmanga.ru/covers/a.jpg');
  });
  test('readerInit mixed quote format parses', () {
    final images = ReadMangaSource().parseReaderPages('''
      <script>readerInit({}, [['https://cdn.example/','','a.jpg',1,2],['https://cdn.example/','',"b.jpg",1,2]])</script>
    ''');
    expect(images.length, 2);
    expect(images.last.url, 'https://cdn.example/b.jpg');
  });

  test('known placeholder links are not considered manga pages', () {
    final images = ReadMangaSource().parseReaderPages("""
      <script>readerInit({}, [
        ['https://3.readmanga.ru/','','/static/deleted1.png',1,2],
        ['https://cdn.example/','','/manga/real-1.jpg',1,2]
      ])</script>
    """);
    expect(images.length, 1);
    expect(images.single.url, 'https://cdn.example//manga/real-1.jpg');
  });

  test('duplicate CDN placeholder bytes fail with readable error', () async {
    final client = MockClient((request) async {
      if (request.url.host == '3.readmanga.ru') {
        expect(request.headers['referer'], 'https://www.google.com/');
        return http.Response('''
          <script>readerInit({}, [
            ['https://cdn.example/','','one.jpg',1,2],
            ['https://cdn.example/','','two.jpg',1,2],
            ['https://cdn.example/','','three.jpg',1,2]
          ])</script>
        ''', 200);
      }
      expect(request.headers['referer'], 'https://www.google.com/');
      return http.Response.bytes(List<int>.filled(8500, 42), 200,
          headers: {'content-type': 'image/jpeg'});
    });
    final source = ReadMangaSource(client: client);
    await expectLater(
      source.pages(const Chapter(id: '/chapter/127', name: 'Глава 127')),
      throwsA(isA<SourceException>().having(
        (e) => e.message, 'message', contains('одинаковая картинка'))),
    );
  });

  test('distinct valid images still open in correct order', () async {
    final client = MockClient((request) async {
      if (request.url.host == '3.readmanga.ru') {
        return http.Response('''
          <script>readerInit({}, [
            ['https://cdn.example/','','one.jpg',1,2],
            ['https://cdn.example/','','two.jpg',1,2],
            ['https://cdn.example/','','three.jpg',1,2]
          ])</script>
        ''', 200);
      }
      final n = request.url.path.contains('one') ? 1 :
          request.url.path.contains('two') ? 2 : 3;
      return http.Response.bytes(List<int>.filled(8500, n), 200,
          headers: {'content-type': 'image/jpeg'});
    });
    final pages = await ReadMangaSource(client: client)
        .pages(const Chapter(id: '/chapter/127', name: 'Глава 127'));
    expect(pages.map((p) => p.url), [
      'https://cdn.example/one.jpg',
      'https://cdn.example/two.jpg',
      'https://cdn.example/three.jpg',
    ]);
    expect(pages.first.headers['Referer'], 'https://www.google.com/');
  });

  test('CDN HTTP 403 fails as unavailable instead of a readable chapter', () async {
    final client = MockClient((request) async {
      if (request.url.host == '3.readmanga.ru') {
        return http.Response("""
          <script>readerInit({}, [
            ['https://cdn.example/','','one.jpg',1,2],
            ['https://cdn.example/','','two.jpg',1,2]
          ])</script>
        """, 200);
      }
      return http.Response('forbidden', 403);
    });
    await expectLater(
      ReadMangaSource(client: client)
          .pages(const Chapter(id: '/chapter/127', name: 'Глава 127')),
      throwsA(isA<SourceException>().having(
        (e) => e.message, 'message', contains('403'))),
    );
  });

}
