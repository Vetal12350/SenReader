import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/page_disk_cache.dart';
import 'package:senreader/ui/cached_page_image.dart';

/// C2: pages of an opened chapter come from disk instead of the network.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 1×1 transparent PNG.
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('senreader_pages'));
  tearDown(() async => root.delete(recursive: true));

  PageDiskCache cache({PageDownloader? downloader, int maxBytes = 1 << 30,
      Duration maxAge = const Duration(days: 1)}) =>
    PageDiskCache(root: () async => root.path, downloader: downloader,
      useIsolate: false, maxBytes: maxBytes, maxAge: maxAge);

  List<PageImage> pages(int count) => [for (var i = 0; i < count; i++)
    PageImage('https://cdn.example.com/c1/$i.jpg', headers: const {'Referer': 'https://src.example/'})];

  test('file names are stable per URL and distinct across URLs', () {
    expect(PageDiskCache.nameFor('https://a/1.jpg'), PageDiskCache.nameFor('https://a/1.jpg'));
    expect(PageDiskCache.nameFor('https://a/1.jpg'), isNot(PageDiskCache.nameFor('https://a/2.jpg')));
  });

  test('prefetch starts at the reopened page, passes headers, skips cached pages', () async {
    final seen = <String>[];
    final store = cache(downloader: (dir, jobs, _) async {
      for (final job in jobs) {
        seen.add(job['url']! as String);
        expect((job['headers']! as Map)['Referer'], 'https://src.example/');
        await File('$dir${Platform.pathSeparator}${job['name']}').writeAsBytes(png);
      }
    });
    final chapter = pages(5);
    await store.prefetch(chapter, from: 3);
    expect(seen.map((u) => u.split('/').last),
      ['3.jpg', '4.jpg', '0.jpg', '1.jpg', '2.jpg']);
    for (final page in chapter) {
      expect(await store.cached(page.url), isNotNull);
    }
  });

  test('a duplicate request while queued is not downloaded twice', () async {
    var calls = 0;
    final store = cache(downloader: (dir, jobs, _) async { calls += jobs.length; });
    final chapter = pages(3);
    await Future.wait([store.prefetch(chapter), store.prefetch(chapter)]);
    expect(calls, 3);
  });

  test('prune removes expired files, then oldest over the size budget', () async {
    final store = cache(maxBytes: 250, maxAge: const Duration(hours: 1));
    final dir = await store.directory();
    Future<File> put(String name, int size, Duration age) async {
      final file = File('$dir${Platform.pathSeparator}$name');
      await file.writeAsBytes(Uint8List(size));
      await file.setLastModified(DateTime.now().subtract(age));
      return file;
    }
    final expired = await put('expired', 10, const Duration(hours: 2));
    final oldest = await put('oldest', 100, const Duration(minutes: 30));
    final middle = await put('middle', 100, const Duration(minutes: 20));
    final newest = await put('newest', 100, const Duration(minutes: 10));
    await store.prune();
    expect(await expired.exists(), isFalse);
    expect(await oldest.exists(), isFalse, reason: 'over 250 bytes: drop oldest');
    expect(await middle.exists(), isTrue);
    expect(await newest.exists(), isTrue);
  });

  test('reader page loads from disk without touching the network', () async {
    final store = cache();
    final page = pages(1).single;
    await store.store(page.url, Uint8List.fromList(png));
    var networkCalls = 0;
    final provider = CachedPageImage(page, cache: store,
      fetch: (_) async { networkCalls++; return Uint8List(0); });
    expect(await provider.loadBytes(), png);
    expect(networkCalls, 0);
  });

  test('network fallback stores the page for the next time', () async {
    final store = cache();
    final page = pages(1).single;
    var networkCalls = 0;
    final provider = CachedPageImage(page, cache: store,
      fetch: (_) async { networkCalls++; return Uint8List.fromList(png); });
    expect(await provider.loadBytes(), png);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await store.cached(page.url), isNotNull);
    expect(await provider.loadBytes(), png);
    expect(networkCalls, 1, reason: 'second load is served from disk');
  });

  test('a failing network page is not cached', () async {
    final store = cache();
    final page = pages(1).single;
    final provider = CachedPageImage(page, cache: store,
      fetch: (_) async => throw const HttpException('403'));
    await expectLater(provider.loadBytes(), throwsA(isA<HttpException>()));
    expect(await store.cached(page.url), isNull);
  });
}
