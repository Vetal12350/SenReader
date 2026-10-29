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
    expect(list.first.coverUrl, 'https://a.zazaza.me/covers/a.jpg');
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
      if (request.url.host == 'a.zazaza.me') {
        expect(request.headers['referer'], 'https://a.zazaza.me/');
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
      if (request.url.host == 'a.zazaza.me') {
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
      if (request.url.host == 'a.zazaza.me') {
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


  test('public chapter 127 uses canonical ZazaZa domain', () async {
    final client = MockClient((request) async {
      expect(request.url.scheme, 'https');
      expect(request.url.host, 'a.zazaza.me');
      expect(request.url.path, '/kak_vyjit_v_akademii/vol2/127');
      return http.Response('''
        <script>readerInit({}, [
          ['https://resrm.one-way.work/','','p001.jpg',1,2],
          ['https://resrm.one-way.work/','','p002.jpg',1,2]
        ])</script>''', 200);
    });
    // Stored legacy absolute chapter links must be migrated transparently.
    // First test parsing without preflight image retrieval.
    final source = ReadMangaSource(client: client);
    final uri = source.canonicalChapterUri(
        'https://3.readmanga.ru/kak_vyjit_v_akademii/vol2/127?mtr=true');
    expect(uri.toString(), 'https://a.zazaza.me/kak_vyjit_v_akademii/vol2/127?mtr=true');
    final newUri = source.canonicalChapterUri('/kak_vyjit_v_akademii/vol2/127');
    expect(newUri.host, 'a.zazaza.me');
  });

  test('legacy favorites preserve source path, external host is rejected', () {
    final source = ReadMangaSource();
    expect(source.canonicalChapterUri('/kak_vyjit_v_akademii').toString(),
        'https://a.zazaza.me/kak_vyjit_v_akademii');
    expect(source.canonicalChapterUri(
        'https://3.readmanga.ru/kak_vyjit_v_akademii').toString(),
        'https://a.zazaza.me/kak_vyjit_v_akademii');
    for (final url in [
      'https://evil.example.org/path',
      'http://3.readmanga.ru/path',
      'https://a.zazaza.me.evil.org/path',
      'https://username:password@a.zazaza.me/path',
    ]) {
      expect(() => source.canonicalChapterUri(url), throwsA(isA<SourceException>()));
    }
  });


  test('live hashed removed image is rejected even if it is a single URL', () async {
    final image = 'https://resrm.one-way.work/static/deleted1-'
        '24d87e88e6e47dc5c7b60c03c0a3e589.png';
    final source = ReadMangaSource(client: MockClient((request) async {
      expect(request.url.host, 'a.zazaza.me');
      expect(request.url.path, '/kak_vyjit_v_akademii/vol2/127');
      return http.Response("""
        <script>readerInit({}, [
          ['https://resrm.one-way.work/','','static/deleted1-24d87e88e6e47dc5c7b60c03c0a3e589.png',1,2]
        ])</script>
      """, 200);
    }));
    final parsed = source.parseReaderPages("""
      <script>readerInit({}, [
        ['https://resrm.one-way.work/','','static/deleted1-24d87e88e6e47dc5c7b60c03c0a3e589.png',1,2]
      ])</script>
    """);
    expect(parsed, isEmpty);
    expect(image, contains('deleted1-'));
    await expectLater(
      source.pages(const Chapter(
          id: '/kak_vyjit_v_akademii/vol2/127', name: 'Глава 127 (т. 2)')),
      throwsA(isA<SourceException>().having(
        (e) => e.message, 'message', contains('недоступе'))),
    );
  });

}
