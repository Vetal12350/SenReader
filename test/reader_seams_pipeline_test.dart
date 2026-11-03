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
    for (var i = 0; i < count; i++) PageImage('${chapter.id}/$i/0'),
  ];
}

const _captureKey = ValueKey('reader-pixel-capture');

Future<ui.Image> bitmap(int width, int height, {bool whiteBottom = false}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xff101010), BlendMode.src);
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
      int physicalWidth = 400, double dpr = 1, int count = 12}) async {
    tester.view.physicalSize = Size(physicalWidth.toDouble(), 600);
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
    (1344, 3.0, .501), (1080, 2.625, .5005),
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

  testWidgets('long short-strip chapter does not start decodes for multiple offscreen screens', (tester) async {
    final (fixtures, _) = await mount(tester, count: 200);
    // Complete newly requested short strips until layout reaches a fixed point.
    for (var round = 0; round < 14; round++) {
      for (final key in fixtures.pending.keys.toList()) { fixtures.complete(key, 60); }
      await tick(tester);
    }
    final list = tester.widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList));
    final visible = list.itemPositionsListener!.itemPositions.value.where((p) =>
      p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1).length;
    expect(fixtures.requested.toSet().length, lessThanOrEqualTo(visible + 6),
      reason: 'pixels outside the bounded near-viewport window should remain lazy');
  });
}
