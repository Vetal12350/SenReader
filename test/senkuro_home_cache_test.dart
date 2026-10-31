import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/senkuro_home_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const entry = MangaEntry(source: 'senkuro', id: 'one',
    title: 'Example', rating: 8.4);
  test('home categories reuse Senkuro data for 24 hours, then expire', () async {
    final cache = SenkuroHomeCache();
    final time = DateTime(2026, 10, 31, 10);
    expect(await cache.load('Top'), isNull);
    await cache.save('Top', [entry], now: time);
    final one = await cache.load('Top', now: time.add(const Duration(hours: 23)));
    expect(one?.single.title, 'Example');
    expect(one?.single.rating, 8.4);
    expect(await cache.load('Top', now: time.add(const Duration(hours: 24))), isNull);
  });
  test('different home categories never overwrite each other', () async {
    final cache = SenkuroHomeCache();
    final time = DateTime(2026, 10, 31, 10);
    await cache.save('Senkuro Manhwa', [entry], now: time);
    expect(await cache.load('Manga', now: time), isNull);
    expect(await cache.load('Senkuro Manhwa', now: time), hasLength(1));
  });
}
