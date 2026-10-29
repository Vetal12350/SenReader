import 'package:flutter_test/flutter_test.dart';
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
}
