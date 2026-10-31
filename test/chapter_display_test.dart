import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/chapter_identity.dart';
import 'package:senreader/core/models.dart';

void main() {
  test('volume suffix removed in UI without changing chapter identity', () {
    const raw = 'Глава 166 (т. 3)';
    expect(displayChapterName(raw), 'Глава 166');
    expect(displayChapterName('Глава 11 (т. 1)'), 'Глава 11');
    expect(displayChapterName('Глава 5.1 (том 2)'), 'Глава 5.1');
    expect(displayChapterName('Глава 167'), 'Глава 167');
    expect(displayChapterName('Глава 168 (1 т)'), 'Глава 168');
    expect(canonicalChapterKey(const Chapter(id: 'abc', name: raw)), 'v3:c166');
  });
}
