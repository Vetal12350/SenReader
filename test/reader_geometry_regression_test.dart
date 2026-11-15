import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  Completer<List<PageImage>>? nextChapter;
  @override Future<List<MangaEntry>> popular() async => [];
  @override Future<List<MangaEntry>> search(String query) async => [];
  @override Future<MangaDetail> detail(MangaEntry entry) async =>
      MangaDetail(entry: entry, chapters: [chapter]);
  @override Future<List<PageImage>> pages(Chapter chapter) async {
    requests++;
    if (chapter.id == '2' && nextChapter != null) return nextChapter!.future;
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
    expect(request, isNotNull, reason: 'No pending decode for $key; requested=$requested');
    request!.complete(ImageInfo(image: bitmaps[height]!.clone()));
  }
}

class _ControlledImage extends ImageProvider<(ControlledImages, String)> {
  const _ControlledImage(this.images, this.id);
  final ControlledImages images;
  final String id;
  @override Future<(ControlledImages, String)> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture((images, id));
  @override ImageStreamCompleter loadImage((ControlledImages, String) key,
      ImageDecoderCallback decode) => OneFrameImageStreamCompleter(images.load(key.$2));
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
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(const Color(0xff0000ff), BlendMode.src);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 400, 200),
        Paint()..color = const Color(0xffff0000));
      final picture = recorder.endRecording();
      bitmaps[height] = await picture.toImage(400, height);
      picture.dispose();
    }
  });
  tearDownAll(() { for (final image in bitmaps.values) { image.dispose(); } });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  Future<(GeometrySource, ControlledImages)> mount(WidgetTester tester,
      {bool continuous = false, Chapter? openingChapter,
       LibraryStore? library}) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = GeometrySource();
    if (continuous) source.nextChapter = Completer<List<PageImage>>();
    final images = ControlledImages(bitmaps);
    await tester.pumpWidget(MaterialApp(home: ReaderPage(book: source.book,
      chapter: openingChapter ?? source.chapter, sourceKey: source.key, chapters: [
        if (continuous) const Chapter(id: '2', name: 'Глава 2'), source.chapter],
      repository: CatalogRepository(sources: {source.key: source}),
      library: library ?? LibraryStore(), imageProviderFactory: images.provider)));
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

  for (final fitHeight in [false, true]) {
  testWidgets('cold offscreen tiles cannot bypass the speculative queue (fitHeight=$fitHeight)', (tester) async {
    SharedPreferences.setMockInitialValues({'senreader.reader.fit_height': fitHeight});
    final (_, images) = await mount(tester);
    images.complete('1/0/0', 6000);
    await tick(tester);
    final listFinder = find.byType(ScrollablePositionedList);
    final list = tester.widget<ScrollablePositionedList>(listFinder);
    // Queue slots remain occupied by slow CDN/decode results. A fast forward
    // window must not let lazy-built Image widgets start additional work.
    final previous = images.requested.toSet();
    for (var i = 0; i < 2; i++) {
      ScrollUpdateNotification(
        metrics: FixedScrollMetrics(minScrollExtent: 0, maxScrollExtent: 100000,
          pixels: 1000, viewportDimension: 800, axisDirection: AxisDirection.down,
          devicePixelRatio: 1),
        context: tester.element(listFinder), scrollDelta: 1600,
      ).dispatch(tester.element(listFinder));
    }
    list.itemScrollController!.jumpTo(index: 5);
    await tick(tester);
    final visible = <int>{};
    for (final element in find.byWidgetPredicate((w) =>
        w.runtimeType.toString() == '_RetryableReaderImage').evaluate()) {
      final rect = tester.getRect(find.byWidget(element.widget));
      if (rect.bottom > 0 && rect.top < 800) {
        final dynamic tile = element.widget;
        visible.add(tile.pageIndex as int);
      }
    }
    final extra = images.requested.where((id) => !previous.contains(id) &&
      !visible.contains(int.parse(id.split('/')[1]))).toList();
    expect(extra, isEmpty,
      reason: 'Only visible pages may bypass occupied speculative slots');
  });
  }

  testWidgets('opening stays at the top when the second image decodes first', (tester) async {
    final (_, images) = await mount(tester);
    final list = find.byType(ScrollablePositionedList);
    final top = tester.getTopLeft(list).dy;
    expect(tester.getTopLeft(page(0)).dy, closeTo(top, 1));
    images.complete('1/1/0', 3000);
    await tick(tester);
    images.complete('1/0/0', 12000);
    await tick(tester);
    expect(tester.getTopLeft(page(0)).dy, closeTo(top, 1));
  });

  testWidgets('reopened chapter keeps its saved page at the top during late decode', (tester) async {
    final source = GeometrySource();
    const chapter = Chapter(id: '2', name: 'Глава 2');
    final previous = LibraryStore();
    await previous.savePosition(source.book, chapter, source.key,
      pageIndex: 3, pageCount: 12);
    await previous.savePosition(source.book, source.chapter, source.key,
      pageIndex: 1, pageCount: 12);
    final reopened = LibraryStore();
    await reopened.load();
    final (_, images) = await mount(tester, openingChapter: chapter, library: reopened);
    final list = find.byType(ScrollablePositionedList);
    final target = find.byKey(const ValueKey('reader-image-2|3-0'));
    final top = tester.getTopLeft(list).dy;
    expect(tester.getTopLeft(target).dy, closeTo(top, 1));
    images.complete('2/4/0', 3000);
    await tick(tester);
    images.complete('2/3/0', 6000);
    await tick(tester);
    expect(tester.getTopLeft(target).dy, closeTo(top, 1));
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

  testWidgets('late geometry during a drag neither moves the anchor nor ends the gesture', (tester) async {
    final (_, images) = await mount(tester);
    images.complete('1/1/0');
    await tick(tester);
    final gesture = await tester.startGesture(const Offset(200, 500));
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -420));
    await tick(tester);
    final viewportTop = tester.getTopLeft(find.byType(ScrollablePositionedList)).dy;
    expect(tester.getTopLeft(page(0)).dy, lessThan(viewportTop - 100));
    final before = tester.getTopLeft(page(1)).dy;
    images.complete('1/0/0', 12000);
    await tick(tester);
    expect(tester.getTopLeft(page(1)).dy, closeTo(before, 1));
    expect(tester.getTopLeft(page(0)).dy, lessThan(viewportTop - 100));
    await gesture.moveBy(const Offset(0, -30));
    await tick(tester);
    expect(tester.getTopLeft(page(1)).dy, closeTo(before - 30, 1));
    final atRelease = tester.getTopLeft(page(1)).dy;
    await gesture.up();
    await tick(tester);
    expect(tester.getTopLeft(page(1)).dy, closeTo(atRelease, 1));
  });

  testWidgets('cache eviction, reverse navigation and CDN failure keep known geometry', (tester) async {
    final (_, images) = await mount(tester);
    images.complete('1/0/0', 6000);
    await tick(tester);
    final list = tester.widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList));
    list.itemScrollController!.jumpTo(index: 8);
    await tick(tester);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    list.itemScrollController!.jumpTo(index: 0);
    await tick(tester);
    expect(tester.getSize(page(0)).height, closeTo(6000, 1));
    expect(images.pending.containsKey('1/0/0'), isTrue);
    images.pending.remove('1/0/0')!.completeError(StateError('fixture CDN failure'));
    await tick(tester);
    expect(tester.getSize(page(0)).height, closeTo(6000, 1));
    await tester.pump(const Duration(milliseconds: 500));
    await tick(tester);
    images.complete('1/0/0', 6000);
    await tick(tester);
    expect(tester.getSize(page(0)).height, closeTo(6000, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('geometry survives width changes independently of decoded cache', (tester) async {
    final (_, images) = await mount(tester);
    images.complete('1/0/0', 6000);
    await tick(tester);
    tester.view.physicalSize = const Size(320, 800);
    await tick(tester);
    expect(tester.getSize(page(0)).height, closeTo(4800, 1));
    final list = tester.widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList));
    list.itemScrollController!.jumpTo(index: 8);
    await tick(tester);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    list.itemScrollController!.jumpTo(index: 0);
    await tick(tester);
    expect(tester.getSize(page(0)).height, closeTo(4800, 1));
  });

  testWidgets('chapter append preserves the preceding visible page and source', (tester) async {
    final (source, images) = await mount(tester, continuous: true);
    final list = tester.widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList));
    list.itemScrollController!.jumpTo(index: 11, alignment: .1);
    await tick(tester);
    images.complete('1/11/0');
    await tick(tester);
    final before = tester.getTopLeft(page(11)).dy;
    source.nextChapter!.complete([const PageImage('2/0/0'), const PageImage('2/1/0')]);
    await tick(tester);
    expect(tester.getTopLeft(page(11)).dy, closeTo(before, 1));
    final updated = tester.widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList));
    expect(updated.itemCount, 16);
    expect(tester.widget<ReaderPage>(find.byType(ReaderPage)).sourceKey, 'senkuro');
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale prefetch after URL refresh cannot publish geometry into a new generation', (tester) async {
    final (source, images) = await mount(tester);
    images.complete('1/0/0', 3000);
    await tick(tester);
    expect(images.pending.containsKey('1/2/0'), isTrue);
    final dynamic tile = tester.widget(page(0));
    source.revision++;
    await tile.onRefreshLinks();
    await tick(tester);
    images.complete('1/2/0', 12000);
    await tick(tester);
    final list = tester.widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList));
    list.itemScrollController!.jumpTo(index: 2);
    await tick(tester);
    expect(tester.getSize(page(2, 1)).height, closeTo(600, 1));
    images.complete('1/2/1', 3000);
    await tick(tester);
    expect(tester.getSize(page(2, 1)).height, closeTo(3000, 1));
  });

  testWidgets('memory pressure retains geometry and repeated rapid direction changes stay valid', (tester) async {
    final (_, images) = await mount(tester);
    images.complete('1/0/0', 6000);
    await tick(tester);
    final dynamic reader = tester.state(find.byType(ReaderPage));
    reader.didHaveMemoryPressure();
    PaintingBinding.instance.imageCache.clear();
    final list = tester.widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList));
    for (final index in [8, 2, 9, 1, 0]) {
      list.itemScrollController!.jumpTo(index: index);
      await tick(tester);
    }
    expect(tester.getSize(page(0)).height, closeTo(6000, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('changed ratio after refresh above the viewport preserves the next known page', (tester) async {
    final (source, images) = await mount(tester);
    images.complete('1/0/0', 3000);
    images.complete('1/1/0', 3000);
    await tick(tester);
    await tester.drag(find.byType(ScrollablePositionedList), const Offset(0, -2840));
    await tick(tester);
    final before = tester.getTopLeft(page(1)).dy;
    expect(before, inExclusiveRange(0, 800));
    final dynamic tile = tester.widget(page(0));
    source.revision++;
    await tile.onRefreshLinks();
    await tick(tester);
    images.complete('1/0/1', 12000);
    await tick(tester);
    expect(tester.getTopLeft(page(1, 1)).dy, closeTo(before, 1));
  });

  testWidgets('first decoded frame and committed geometry show the same top pixels', (tester) async {
    final (_, images) = await mount(tester);
    images.complete('1/0/0', 3000);
    await tester.pump(); // decoded frame, before the next layout/ratio commit
    Future<List<int>> pixel() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byType(RepaintBoundary).first);
      return (await tester.runAsync(() async {
        final shot = await boundary.toImage();
        final bytes = (await shot.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        final offset = (10 * shot.width + 10) * 4;
        final color = bytes.buffer.asUint8List(bytes.offsetInBytes + offset, 4).toList();
        shot.dispose();
        return color;
      }))!;
    }
    expect(await pixel(), [255, 0, 0, 255]);
    await tick(tester);
    expect(await pixel(), [255, 0, 0, 255]);
  });

  testWidgets('timeout keeps speculative request slots charged and dispose rejects late results', (tester) async {
    final (_, images) = await mount(tester);
    images.complete('1/0/0', 3000);
    await tick(tester);
    final requested = images.requested.length;
    expect(images.pending.containsKey('1/2/0'), isTrue);
    expect(images.pending.containsKey('1/3/0'), isTrue);
    await tester.pump(const Duration(seconds: 13));
    await tick(tester);
    expect(images.requested.length, requested,
      reason: 'a soft timeout must not launch more HTTP behind unfinished requests');
    await tester.pumpWidget(const SizedBox());
    images.complete('1/2/0', 12000);
    images.complete('1/3/0', 6000);
    await tick(tester);
    expect(tester.takeException(), isNull);
  });
}
