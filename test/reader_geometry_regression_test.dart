import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/core/source.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/ui/reader_page.dart';

class GeometrySource implements MangaSource {
  @override String get key => 'senkuro';
  @override String get name => key;
  @override Map<String, String> get imageHeaders => const {};
  final chapter = const Chapter(id: '1', name: 'Глава 1');
  int revision = 0;
  int requests = 0;
  @override Future<List<MangaEntry>> popular() async => [];
  @override Future<List<MangaEntry>> search(String query) async => [];
  @override Future<MangaDetail> detail(MangaEntry entry) async =>
      MangaDetail(entry: entry, chapters: [chapter]);
  @override Future<List<PageImage>> pages(Chapter chapter) async {
    requests++;
    return [for (var i = 0; i < 12; i++) PageImage('${chapter.id}/$i/$revision')];
  }
  UnifiedManga get book => UnifiedManga(title: 'Geometry fixture', entries: {
    key: MangaEntry(source: key, id: 'fixture', title: 'Geometry fixture'),
  });
}

/// CDN/decode completion are controlled independently of scrolling. Actual
/// ui.Images include 3000/6000/12000px strips; no external HTTP is used.
class ControlledImages {
  final pending = <String, Completer<ImageInfo>>{};
  final requested = <String>[];
  final Map<int, ui.Image> bitmaps;
  ControlledImages(this.bitmaps);
  ImageProvider provider(PageImage page, int width) => _ControlledImage(this, page.url);
  Future<ImageInfo> load(String key) {
    requested.add(key);
    return (pending[key] = Completer<ImageInfo>()).future;
  }
  void complete(String key, [int height = 3000]) {
    final request = pending.remove(key);
    if (request != null && !request.isCompleted) {
      request.complete(ImageInfo(image: bitmaps[height]!.clone()));
    }
  }
}

class _ControlledImage extends ImageProvider<String> {
  const _ControlledImage(this.images, this.id);
  final ControlledImages images;
  final String id;
  @override Future<String> obtainKey(ImageConfiguration configuration) => SynchronousFuture(id);
  @override ImageStreamCompleter loadImage(String key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(images.load(key));
}

Future<void> tick(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) { await tester.pump(const Duration(milliseconds: 16)); }
}
Finder page(int index, [int revision = 0]) =>
    find.byKey(ValueKey('reader-image-1|$index-$revision'));

void main() {
  final bitmaps = <int, ui.Image>{};
  setUpAll(() async {
    for (final height in [3000, 6000, 12000]) {
      bitmaps[height] = await createTestImage(width: 400, height: height, cache: false);
    }
  });
  tearDownAll(() { for (final image in bitmaps.values) { image.dispose(); } });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  Future<(GeometrySource, ControlledImages)> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = GeometrySource();
    final images = ControlledImages(bitmaps);
    await tester.pumpWidget(MaterialApp(home: ReaderPage(book: source.book,
      chapter: source.chapter, sourceKey: source.key, chapters: [source.chapter],
      repository: CatalogRepository(sources: {source.key: source}),
      library: LibraryStore(), imageProviderFactory: images.provider)));
    await tick(tester);
    return (source, images);
  }

  testWidgets('prefetch completion does not rebuild the reader root', (tester) async {
    final (_, images) = await mount(tester);
    var rootBuilds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is ReaderPage) rootBuilds++;
      previous?.call(element, builtOnce);
    };
    addTearDown(() { debugOnRebuildDirtyWidget = previous; });
    expect(images.pending.containsKey('1/1/0'), isTrue);
    images.complete('1/1/0', 12000);
    await tick(tester);
    expect(rootBuilds, 0);
  });

  testWidgets('late tall image above a visible decoded page preserves its screen position', (tester) async {
    final (_, images) = await mount(tester);
    images.complete('1/1/0', 3000);
    await tick(tester);
    await tester.drag(find.byType(ScrollablePositionedList), const Offset(0, -440));
    await tick(tester);
    final before = tester.getTopLeft(page(1)).dy;
    expect(before, inExclusiveRange(0, 800));
    images.complete('1/0/0', 12000);
    await tick(tester);
    expect(tester.getTopLeft(page(1)).dy, closeTo(before, 1));
  });

  testWidgets('URL refresh keeps known strip height while replacement is pending', (tester) async {
    final (source, images) = await mount(tester);
    images.complete('1/0/0', 6000);
    await tick(tester);
    final before = tester.getSize(page(0)).height;
    expect(before, closeTo(6000, 1));
    final dynamic tile = tester.widget(page(0));
    source.revision++;
    await tile.onRefreshLinks();
    await tick(tester);
    expect(tester.getSize(page(0, 1)).height, closeTo(before, 1));
    images.complete('1/0/1', 6000);
    await tick(tester);
    expect(tester.getSize(page(0, 1)).height, closeTo(before, 1));
  });
}
