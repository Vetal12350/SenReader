import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/ui/reader_page.dart';
import 'reader_geometry_regression_test.dart' show GeometrySource, ControlledImages, tick, page;

class _ManyStrips extends GeometrySource {
  _ManyStrips(this.count);
  final int count;
  @override Future<List<PageImage>> pages(Chapter chapter) async => [
    for (var i = 0; i < count; i++) PageImage('${chapter.id}/$i/$revision'),
  ];
}

const _captureKey = ValueKey('reader-pixel-capture');

Future<ui.Image> bitmap(int width, int height,
    {bool whiteBottom = false, bool transparent = false}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(transparent ? Colors.transparent : const Color(0xff101010), BlendMode.src);
  if (whiteBottom) {
    canvas.drawRect(Rect.fromLTWH(0, height - 1, width.toDouble(), 1),
      Paint()..color = Colors.white);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  return image;
}

Future<List<List<int>>> seamPixels(WidgetTester tester, double dpr,
    double alignment) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
  return (await tester.runAsync(() async {
    final shot = await boundary.toImage(pixelRatio: dpr);
    final data = (await shot.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final center = (shot.height * alignment).floor();
    final result = <List<int>>[
      for (var y = center - 3; y <= center + 3; y++)
        bytes.sublist((y * shot.width + shot.width ~/ 2) * 4,
          (y * shot.width + shot.width ~/ 2) * 4 + 4),
    ];
    shot.dispose();
    return result;
  }))!;
}

void main() {
  final images = <int, ui.Image>{};
  setUpAll(() async {
    images[197] = await bitmap(113, 197);
    images[60] = await bitmap(400, 60);
    images[1200] = await bitmap(777, 1200);
    images[1201] = await bitmap(778, 1201);
    images[198] = await bitmap(113, 197, whiteBottom: true);
    images[199] = await bitmap(113, 197, transparent: true);
    images[600] = await bitmap(113, 600);
  });
  tearDownAll(() { for (final image in images.values) { image.dispose(); } });
  setUp(() => SharedPreferences.setMockInitialValues({
    'senreader.reader.light_theme': true,
  }));
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  Future<(ControlledImages, LibraryStore)> mount(WidgetTester tester, {
      int physicalWidth = 400, double dpr = 1, int count = 12,
      int physicalHeight = 600}) async {
    tester.view.physicalSize = Size(physicalWidth.toDouble(), physicalHeight.toDouble());
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = _ManyStrips(count);
    final fixtures = ControlledImages(images);
    final library = LibraryStore();
    await tester.pumpWidget(RepaintBoundary(key: _captureKey,
      child: MaterialApp(home: ReaderPage(book: source.book, chapter: source.chapter,
        chapters: [source.chapter], sourceKey: source.key, library: library,
        repository: CatalogRepository(sources: {source.key: source}),
        imageProviderFactory: fixtures.provider))));
    await tick(tester);
    return (fixtures, library);
  }

  for (final (width, dpr, alignment) in [
    (400, 1.0, .5), (537, 1.25, .501),
    (1344, 3.0, .501), (1080, 2.625, .5005), (1008, 2.25, .36),
  ]) {
    testWidgets('opaque source has no bright seam: $width px DPR $dpr at $alignment', (tester) async {
      final (fixtures, _) = await mount(tester, physicalWidth: width, dpr: dpr);
      fixtures.complete('1/0/0', 197);
      fixtures.complete('1/1/0', 197);
      await tick(tester);
      final list = tester.widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList));
      list.itemScrollController!.jumpTo(index: 1, alignment: alignment);
      await tick(tester);
      final pixels = await seamPixels(tester, dpr, alignment);
      expect(pixels.every((p) => p[0] <= 20 && p[1] <= 20 && p[2] <= 20 && p[3] == 255),
        isTrue, reason: 'the source has no white/transparent edge; seam pixels=$pixels');
    });
  }

  testWidgets('Pixel 8 Pro dimensions stay joined across fractional physical offsets', (tester) async {
    const dpr = 2.625;
    final (fixtures, _) = await mount(tester,
      physicalWidth: 1008, physicalHeight: 2244, dpr: dpr);
    fixtures.complete('1/0/0', 197);
    fixtures.complete('1/1/0', 197);
    await tick(tester);
    final list = tester.widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList));
    for (final offset in [0.0, .125, .25, .375, .5, .625, .75, .875]) {
      final alignment = .5 + offset / 2244;
      list.itemScrollController!.jumpTo(index: 1, alignment: alignment);
      await tick(tester);
      final pixels = await seamPixels(tester, dpr, alignment);
      expect(pixels.every((p) => p[0] <= 20 && p[1] <= 20 && p[2] <= 20 && p[3] == 255),
        isTrue, reason: 'fractional physical offset=$offset, seam pixels=$pixels');
    }
  });

  testWidgets('long short-strip chapter does not start decodes for multiple offscreen screens', (tester) async {
    final (fixtures, _) = await mount(tester, count: 200);
    // Complete newly requested short strips until layout reaches a fixed point.
    for (var round = 0; round < 14; round++) {
      for (final key in fixtures.pending.keys.toList()) { fixtures.complete(key, 60); }
      await tick(tester);
    }
    var visible = 0;
    for (var index = 0; index < 200; index++) {
      final finder = page(index);
      if (finder.evaluate().isEmpty) continue;
      final rect = tester.getRect(finder);
      if (rect.bottom > 0 && rect.top < 600) visible++;
    }
    debugPrint('ReaderShortStripFixture visible=$visible imageStarts=${fixtures.requested.toSet().length}');
    expect(visible, 10, reason: 'the viewport must fill with decoded 60px strips, not stalled placeholders');
    for (var index = 0; index < visible; index++) {
      expect(tester.getSize(page(index)).height, closeTo(60, 1e-6));
    }
    expect(fixtures.requested.toSet().length, lessThanOrEqualTo(visible + 6),
      reason: 'pixels outside the bounded near-viewport window should remain lazy');
  });

  testWidgets('subpixel ratio change after URL refresh cannot leave a bright letterbox seam', (tester) async {
    final (fixtures, _) = await mount(tester, physicalWidth: 1200,
      physicalHeight: 1800, dpr: 3);
    for (final key in ['1/0/0', '1/1/0', '1/2/0']) { fixtures.complete(key, 1200); }
    await tick(tester);
    final source = tester.widget<ReaderPage>(find.byType(ReaderPage)).repository.sources['senkuro']!
        as GeometrySource;
    final dynamic tile = tester.widget(page(0));
    source.revision++;
    await tile.onRefreshLinks();
    await tick(tester);
    // The new decoded ratio differs by less than one logical pixel. Both
    // opaque fixtures have entirely dark borders: no source white line exists.
    for (final key in ['1/0/1', '1/1/1', '1/2/1']) { fixtures.complete(key, 1201); }
    await tick(tester);
    final list = tester.widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList));
    list.itemScrollController!.jumpTo(index: 2, alignment: .5);
    await tick(tester);
    final pixels = await seamPixels(tester, 3, .5);
    expect(pixels.every((p) => p[0] <= 20 && p[1] <= 20 && p[2] <= 20), isTrue,
      reason: 'no letterboxing is permitted after the new intrinsic ratio is known: $pixels');
    expect(tester.getSize(page(1, 1)).height, closeTo(400 * 1201 / 778, 1e-6));
  });

  testWidgets('visible and prefetch decode width follow the actual reader viewport', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = _ManyStrips(12);
    final fixtures = ControlledImages(images);
    final widths = <int>{};
    await tester.pumpWidget(MaterialApp(home: Align(alignment: Alignment.topLeft,
      child: SizedBox(width: 400, child: ReaderPage(book: source.book,
        chapter: source.chapter, chapters: [source.chapter], sourceKey: source.key,
        library: LibraryStore(), repository: CatalogRepository(sources: {source.key: source}),
        imageProviderFactory: (image, width) {
          widths.add(width);
          return fixtures.provider(image, width);
        })))));
    await tick(tester);
    expect(widths, {400}, reason: '800px MediaQuery is not the 400px reader pane');
  });

  testWidgets('an original white edge is preserved rather than cropped or covered', (tester) async {
    final (fixtures, _) = await mount(tester, physicalWidth: 537, dpr: 1.25);
    fixtures.complete('1/0/0', 198);
    fixtures.complete('1/1/0', 197);
    await tick(tester);
    final list = tester.widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList));
    list.itemScrollController!.jumpTo(index: 1, alignment: .5);
    await tick(tester);
    final pixels = await seamPixels(tester, 1.25, .5);
    expect(pixels.any((p) => p[0] > 200 && p[1] > 200 && p[2] > 200), isTrue);
    expect(pixels.last[0], lessThan(30));
  });

  testWidgets('late geometry keeps the anchor and transparent next page intact during a drag', (tester) async {
    final (fixtures, _) = await mount(tester);
    fixtures.complete('1/0/0', 197);
    fixtures.complete('1/1/0', 199);
    await tick(tester);
    final list = tester.widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList));
    list.itemScrollController!.jumpTo(index: 1, alignment: .5);
    await tick(tester);
    final reserved = tester.getSize(page(0)).height;
    final gesture = await tester.startGesture(const Offset(200, 550));
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    final dynamic tile = tester.widget(page(0));
    final source = tester.widget<ReaderPage>(find.byType(ReaderPage))
        .repository.sources['senkuro']! as GeometrySource;
    source.revision++;
    await tile.onRefreshLinks();
    await tick(tester);
    fixtures.complete('1/0/1', 600);
    fixtures.complete('1/1/1', 199);
    await tick(tester);
    // Geometry above the anchor must stay deferred until the gesture ends.
    expect(tester.getSize(page(0, 1)).height, closeTo(reserved, 1e-6));
    final alignment = tester.getTopLeft(page(1, 1)).dy / 600;
    final pixels = await seamPixels(tester, 1, alignment);
    expect(pixels.last, [255, 255, 255, 255],
      reason: 'the transparent next page must expose the white background, not the overflowing bitmap');
    await gesture.up();
    await tick(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fast return and reopening a long chapter preserve page progress and cached pixels', (tester) async {
    final (fixtures, library) = await mount(tester, count: 200);
    for (var round = 0; round < 12; round++) {
      for (final key in fixtures.pending.keys.toList()) { fixtures.complete(key, 60); }
      await tick(tester);
    }
    final list = tester.widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList));
    for (final index in [80, 5, 90, 80]) {
      list.itemScrollController!.jumpTo(index: index);
      await tick(tester);
    }
    for (var round = 0; round < 12; round++) {
      for (final key in fixtures.pending.keys.toList()) { fixtures.complete(key, 60); }
      await tick(tester);
    }
    await tester.pump(const Duration(milliseconds: 700));
    await tick(tester);
    await library.load();
    expect(library.items.single.lastPageIndex, 80);
    final history = Set<String>.from(library.items.single.readChapterKeys);
    final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
    final beforeRequests = fixtures.requested.where((key) => key == '1/80/0').length;
    await tester.pumpWidget(const SizedBox());
    await tick(tester);
    await tester.pumpWidget(RepaintBoundary(key: _captureKey,
      child: MaterialApp(home: ReaderPage(book: reader.book, chapter: reader.chapter,
        chapters: reader.chapters, sourceKey: reader.sourceKey,
        library: library, repository: reader.repository, imageProviderFactory: fixtures.provider))));
    await tick(tester);
    expect(tester.getTopLeft(page(80)).dy, closeTo(0, 1));
    expect(fixtures.requested.where((key) => key == '1/80/0').length, beforeRequests);
    await library.load();
    expect(library.items.single.lastPageIndex, 80);
    expect(library.items.single.lastSource, 'senkuro');
    expect(library.items.single.readChapterKeys, history);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fit-height keeps visible pages loadable after a distant jump', (tester) async {
    SharedPreferences.setMockInitialValues({'senreader.reader.fit_height': true});
    final (fixtures, _) = await mount(tester);
    fixtures.complete('1/0/0', 197);
    await tick(tester);
    final list = tester.widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList));
    list.itemScrollController!.jumpTo(index: 8);
    await tick(tester);
    expect(fixtures.pending.containsKey('1/8/0'), isTrue);
    fixtures.complete('1/8/0', 197);
    await tick(tester);
    expect(tester.getSize(page(8)).height, closeTo(600, 1));
    expect(tester.takeException(), isNull);
  });
}
