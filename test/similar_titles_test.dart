import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/similar_titles.dart';

void main() {
  const entries = [
    MangaEntry(source: 'senkuro', id: 'x', title: 'Исходная',
      tags: ['Экшен', 'Фэнтези']),
    MangaEntry(source: 'senkuro', id: 'a', title: 'Похожая',
      tags: ['Экшен', 'Фэнтези']),
    MangaEntry(source: 'senkuro', id: 'b', title: 'Частично похожая',
      tags: ['Фэнтези']),
    MangaEntry(source: 'senkuro', id: 'c', title: 'Не похожая',
      tags: ['Романтика']),
    MangaEntry(source: 'senkuro', id: 'd', title: 'ПОХОЖАЯ',
      tags: ['Экшен']),
    MangaEntry(source: 'readmanga', id: 'e', title: 'Без меток'),
  ];

  test('ranks real label intersections, excludes self and duplicates', () {
    expect(similarBySourceTags('Исходная', ['Экшен', 'Фэнтези'], entries)
        .map((e) => e.title).toList(),
      ['Похожая', 'Частично похожая']);
  });
  test('no invented suggestions for missing metadata', () {
    expect(similarBySourceTags('Исходная', [], entries), isEmpty);
    expect(similarBySourceTags('Исходная', ['Неизвестный'], entries), isEmpty);
  });
  test('results are bounded', () {
    expect(similarBySourceTags('Исходная', ['Экшен', 'Фэнтези'],
      entries, limit: 1).length, 1);
  });
}
