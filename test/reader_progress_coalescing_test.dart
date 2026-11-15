import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:senreader/core/models.dart';
import 'package:senreader/data/catalog_repository.dart';
import 'package:senreader/data/library_store.dart';
import 'package:senreader/ui/reader_page.dart';
import 'reader_geometry_regression_test.dart' show GeometrySource, tick;

class _Writes extends LibraryStore {
  final pages = <int>[];
  Completer<void>? blocked;
  bool failNext = false;
  @override Future<void> savePosition(UnifiedManga book, Chapter chapter,
      String source, {required int pageIndex, required int pageCount,
      String? expectedProfile}) async {
    pages.add(pageIndex);
    await blocked?.future;
    if (failNext) {
      failNext = false;
      throw StateError('fixture storage failure');
    }
    await super.savePosition(book, chapter, source, pageIndex: pageIndex,
      pageCount: pageCount, expectedProfile: expectedProfile);
  }
}

void main() {
  const next = Chapter(id: '2', name: 'Глава 2');

  Future<(_Writes, ScrollablePositionedList)> mount(WidgetTester tester,
      {bool twoChapters = false}) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = GeometrySource();
    final library = _Writes();
    await tester.pumpWidget(MaterialApp(home: ReaderPage(book: source.book,
      chapter: source.chapter,
      chapters: [if (twoChapters) next, source.chapter], sourceKey: source.key,
      library: library, repository: CatalogRepository(sources: {source.key: source}))));
    await tick(tester);
    library.pages.clear();
    return (library, tester.widget<ScrollablePositionedList>(
      find.byType(ScrollablePositionedList)));
  }

  testWidgets('a slow gesture coalesces writes and saves the last page when idle', (tester) async {
    final (library, _) = await mount(tester);
    final gesture = await tester.startGesture(const Offset(200, 750));
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -650));
    await tick(tester);
    await tester.pump(const Duration(milliseconds: 700));
    expect(library.pages, isEmpty, reason: 'no full-library write in this gesture');
    await gesture.moveBy(const Offset(0, -650));
    await tick(tester);
    await tester.pump(const Duration(milliseconds: 700));
    expect(library.pages, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    await tick(tester);
    expect(library.pages, [2]);
    await library.load();
    expect(library.items.single.lastPageIndex, 2);
  });

  testWidgets('long motion has a bounded checkpoint interval', (tester) async {
    final (library, _) = await mount(tester);
    final gesture = await tester.startGesture(const Offset(200, 750));
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -650));
    await tick(tester);
    await tester.pump(const Duration(seconds: 4));
    expect(library.pages, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    await tick(tester);
    expect(library.pages, [1]);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('A2: checkpoint never writes between frames of an active drag', (tester) async {
    final (library, _) = await mount(tester);
    final gesture = await tester.startGesture(const Offset(200, 750));
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -650));
    await tick(tester);
    // Keep the list moving every 100 ms past the 5 s checkpoint.
    for (var i = 0; i < 70; i++) {
      await gesture.moveBy(const Offset(0, -2));
      await tester.pump(const Duration(milliseconds: 100));
      expect(library.pages, isEmpty, reason: 'write during motion at ${i * 100} ms');
    }
    // Motion pauses with the finger still down: the checkpoint runs now.
    await tester.pump(const Duration(milliseconds: 400));
    await tick(tester);
    expect(library.pages, hasLength(1));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('A2: continuous motion still checkpoints within the hard cap', (tester) async {
    final (library, _) = await mount(tester);
    final gesture = await tester.startGesture(const Offset(200, 750));
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -650));
    await tick(tester);
    for (var i = 0; i < 170 && library.pages.isEmpty; i++) {
      await gesture.moveBy(const Offset(0, -1));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(library.pages, hasLength(1), reason: 'bounded by saveCheckpointHardCap');
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('returning before debounce saves the actual last visible page', (tester) async {
    final (library, list) = await mount(tester);
    list.itemScrollController!.jumpTo(index: 3);
    await tick(tester);
    list.itemScrollController!.jumpTo(index: 0);
    await tick(tester);
    await tester.pump(const Duration(milliseconds: 700));
    await tick(tester);
    await library.load();
    expect(library.items.single.lastPageIndex, 0);
    expect(library.pages, isEmpty, reason: 'page zero is already durable');
  });

  testWidgets('pause flushes pending progress without waiting for debounce', (tester) async {
    final (library, list) = await mount(tester);
    list.itemScrollController!.jumpTo(index: 3);
    await tick(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tick(tester);
    expect(library.pages, [3]);
    await library.load();
    expect(library.items.single.lastPageIndex, 3);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('leaving drains newer progress after an older blocked write', (tester) async {
    final (library, list) = await mount(tester);
    library.blocked = Completer<void>();
    list.itemScrollController!.jumpTo(index: 2);
    await tick(tester);
    await tester.pump(const Duration(milliseconds: 700));
    expect(library.pages, [2]);
    list.itemScrollController!.jumpTo(index: 4);
    await tick(tester);
    await tester.pumpWidget(const SizedBox());
    final blocked = library.blocked!;
    library.blocked = null;
    blocked.complete();
    await tick(tester);
    expect(library.pages, [2, 4]);
    await library.load();
    expect(library.items.single.lastPageIndex, 4);
    expect(library.items.single.lastSource, 'senkuro');
  });

  testWidgets('failed progress write can retry the same page', (tester) async {
    final (library, list) = await mount(tester);
    library.failNext = true;
    list.itemScrollController!.jumpTo(index: 2);
    await tick(tester);
    await tester.pump(const Duration(milliseconds: 700));
    await tick(tester);
    await tester.pump(const Duration(milliseconds: 700));
    await tick(tester);
    expect(library.pages, [2, 2]);
    await library.load();
    expect(library.items.single.lastPageIndex, 2);
  });

  testWidgets('rapid chapter changes and app teardown keep the final position', (tester) async {
    final (library, firstList) = await mount(tester, twoChapters: true);
    firstList.itemScrollController!.jumpTo(index: 2);
    await tick(tester);
    await tester.tapAt(const Offset(200, 400));
    await tester.pump();
    await tester.tap(find.byTooltip('Следующая глава'));
    await tester.pumpAndSettle();
    final list = find.byType(ScrollablePositionedList);
    expect(tester.widget<ReaderPage>(find.byType(ReaderPage)).chapter.id, next.id);
    expect(tester.widget<ScrollablePositionedList>(list).initialScrollIndex, 0);
    tester.widget<ScrollablePositionedList>(list).itemScrollController!.jumpTo(index: 3);
    await tick(tester);
    await tester.tapAt(const Offset(200, 400));
    await tester.pump();
    await tester.tap(find.byTooltip('Предыдущая глава'));
    await tester.pumpAndSettle();
    expect(tester.widget<ReaderPage>(find.byType(ReaderPage)).chapter.id, '1');
    expect(tester.widget<ScrollablePositionedList>(list).initialScrollIndex, 2);
    tester.widget<ScrollablePositionedList>(list).itemScrollController!.jumpTo(index: 4);
    await tick(tester);
    await tester.pumpWidget(const SizedBox());
    await tick(tester);

    expect(library.pages.where((page) => page > 0), [2, 3, 2, 4]);
    final reopened = LibraryStore();
    await reopened.load();
    expect(reopened.items.single.lastChapterId, '1');
    expect(reopened.items.single.lastPageIndex, 4);
    expect(reopened.items.single.pageIndexFor(next, 'senkuro'), 3);
    expect(reopened.items.single.pageIndexFor(next, 'readmanga'), 0);
  });
}
