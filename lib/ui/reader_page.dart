import 'dart:async';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../core/models.dart';
import '../core/chapter_identity.dart';
import '../data/catalog_repository.dart';
import '../data/library_store.dart';
import '../data/reading_completion.dart';

/// Chapter page URLs are kept as lightweight metadata; the indexed list
/// lazily builds image widgets, so scrolling does not retain all image widgets.
class _ChapterSegment {
  const _ChapterSegment(this.chapter, this.pages);
  final Chapter chapter;
  final List<PageImage> pages;
}

class _VisibleChapterPage {
  const _VisibleChapterPage(this.chapter, this.index, this.total);
  final Chapter chapter;
  final int index;
  final int total;
  String get key => '${chapter.id}|$index';
}

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.book, required this.chapter,
    required this.sourceKey, required this.repository, required this.library,
    this.chapters = const []});
  final List<Chapter> chapters;
  final UnifiedManga book;
  final Chapter chapter;
  final String sourceKey;
  final CatalogRepository repository;
  final LibraryStore library;
  @override State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late final Future<List<PageImage>> future;
  final ItemPositionsListener _positions = ItemPositionsListener.create();
  Timer? _saveTimer;
  int _pageCount = 0;
  String? _lastSavedKey;
  _VisibleChapterPage? _pendingPosition;
  Future<void> _saveChain = Future<void>.value();
  final List<_ChapterSegment> _segments = [];
  final Set<String> _loadedPageKeys = {};
  final Set<String> _autoCompletedChapters = {};
  // Explicit unread actions take precedence over automatic completion.
  final Set<String> _manuallyUnreadChapters = {};
  bool _hasForwardScrolled = false;
  bool _reachedScrollableEnd = false;
  Future<void> _autoMarkChain = Future<void>.value();
  late Chapter _activeChapter;
  bool _nextLoading = false;
  bool _nextScheduled = false;
  bool _atSeriesEnd = false;
  String? _nextError;
  final ValueNotifier<int> _visiblePage = ValueNotifier(0);
  late List<Chapter> _chapters;
  bool _loadingChapters = false;
  // Distraction-free by default; users reveal controls with a central tap.
  bool _controlsVisible = false;
  void _onCenterTap(TapUpDetails details, Size viewport) {
    // The real reader viewport may differ from MediaQuery's logical size
    // (tests, split-screen, inset/resized windows).
    final size = viewport;
    final point = details.localPosition;
    if (point.dx < size.width * 0.22 || point.dx > size.width * 0.78 ||
        point.dy < size.height * 0.2 || point.dy > size.height * 0.8) {
      return;
    }
    if (mounted) setState(() => _controlsVisible = !_controlsVisible);
  }

  @override void initState() {
    super.initState();
    _chapters = widget.chapters;
    _activeChapter = widget.chapter;
    _visiblePage.value = _resumePage;
    future = widget.repository.sources[widget.sourceKey]!.pages(widget.chapter).then((pages) {
      if (mounted) {
        setState(() {
          _segments.add(_ChapterSegment(widget.chapter, pages));
          // Restored progress proves earlier pages were already traversed.
          // The last image must still load before this chapter auto-completes.
          for (var i = 0; i < _resumePage && i < pages.length; i++) {
            _loadedPageKeys.add(
              _VisibleChapterPage(widget.chapter, i, pages.length).key);
          }
          _pageCount = pages.length;
        });
      }
      return pages;
    });
    _positions.itemPositions.addListener(_onVisiblePages);
  }

  int get _resumePage {
    final saved = widget.library.get(widget.book);
    if (saved == null || saved.lastSource != widget.sourceKey) return 0;
    if (saved.lastChapterId.isNotEmpty) {
      return saved.lastChapterId == widget.chapter.id ? saved.lastPageIndex : 0;
    }
    return saved.lastChapter == widget.chapter.name ? saved.lastPageIndex : 0;
  }

  int get _itemCount {
    var count = 1; // End of available chapters / loading footer.
    for (var i = 0; i < _segments.length; i++) {
      if (i > 0) count++; // Boundary label between chapters.
      count += _segments[i].pages.length;
    }
    return count;
  }

  /// Maps a lazily built list item to its source-specific chapter and page.
  /// Headers and the final footer do not change reading progress.
  _VisibleChapterPage? _pageAt(int index) {
    var offset = 0;
    for (var i = 0; i < _segments.length; i++) {
      if (i > 0) offset++;
      final part = _segments[i];
      if (index >= offset && index < offset + part.pages.length) {
        return _VisibleChapterPage(part.chapter, index - offset, part.pages.length);
      }
      offset += part.pages.length;
    }
    return null;
  }

  bool _isHeaderAt(int index) {
    var offset = 0;
    for (var i = 0; i < _segments.length; i++) {
      if (i > 0) {
        if (index == offset) return true;
        offset++;
      }
      offset += _segments[i].pages.length;
    }
    return false;
  }

  Chapter? _headerChapterAt(int index) {
    var offset = 0;
    for (var i = 0; i < _segments.length; i++) {
      if (i > 0) {
        if (index == offset) return _segments[i].chapter;
        offset++;
      }
      offset += _segments[i].pages.length;
    }
    return null;
  }

  /// Only actual forward reading past successfully loaded pages completes
  /// a chapter. Simply opening its last page or an error tile does not.
  void _autoCompletePassedChapters(Iterable<ItemPosition> items) {
    if (!_hasForwardScrolled || _segments.isEmpty) return;
    final visible = items.where((item) =>
      item.itemTrailingEdge > 0 && item.itemLeadingEdge < 1).toList();
    if (visible.isEmpty) return;
    var endIndex = 0;
    for (var i = 0; i < _segments.length; i++) {
      final segment = _segments[i];
      endIndex += segment.pages.length;
      final passed = i < _segments.length - 1
          ? visible.any((item) => item.index > endIndex) &&
            !visible.any((item) => item.index < endIndex)
          : terminalChapterBoundaryReached(
              forwardScrolled: _hasForwardScrolled,
              reachedScrollableEnd: _reachedScrollableEnd,
              footerVisible: visible.any((item) => item.index == _itemCount - 1));
      if (chapterFullyRead(
          forwardScrolled: _hasForwardScrolled,
          passedChapterBoundary: passed,
          pageCount: segment.pages.length,
          alreadyCompleted: _autoCompletedChapters.contains(segment.chapter.id) ||
            _manuallyUnreadChapters.contains(segment.chapter.id),
          loadedPages: [
            for (var page = 0; page < segment.pages.length; page++)
              if (_loadedPageKeys.contains(
                _VisibleChapterPage(segment.chapter, page,
                  segment.pages.length).key)) page,
          ])) {
        _autoCompletedChapters.add(segment.chapter.id);
        final chapter = segment.chapter;
        _autoMarkChain = _autoMarkChain.then((_) async {
          if (_manuallyUnreadChapters.contains(chapter.id)) return;
          await _flushPosition();
          if (_manuallyUnreadChapters.contains(chapter.id)) return;
          await widget.library.markRead(widget.book, chapter, widget.sourceKey,
            availableChapters: _chapters);
        }).catchError((Object _) {
          // A failed persistence write must not permanently suppress a retry.
          _autoCompletedChapters.remove(chapter.id);
        });
      }
      endIndex++; // Chapter separator (or terminal footer).
    }
  }

  void _registerLoadedPage(_VisibleChapterPage item) {
    if (_loadedPageKeys.contains(item.key)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadedPageKeys.add(item.key);
      _autoCompletePassedChapters(_positions.itemPositions.value);
    });
  }

  void _onVisiblePages() {
    if (_segments.isEmpty) return;
    final visible = _positions.itemPositions.value.where((position) =>
      position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1).toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    _VisibleChapterPage? first;
    var nearLastPartEnd = false;
    final last = _segments.last;
    for (final position in visible) {
      final page = _pageAt(position.index);
      if (page == null) continue;
      first ??= page;
      if (page.chapter.id == last.chapter.id &&
          page.index >= last.pages.length - 2) {
        nearLastPartEnd = true;
      }
    }

    _autoCompletePassedChapters(visible);
    if (nearLastPartEnd && !_nextLoading && !_nextScheduled &&
        !_atSeriesEnd && _nextError == null) {
      _nextScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _nextScheduled = false;
        if (mounted) unawaited(_appendNextChapter());
      });
    }

    if (first == null) return;
    final progress = first;
    if (_activeChapter.id != progress.chapter.id) {
      _saveTimer?.cancel();
      unawaited(_flushPosition());
      setState(() {
        _activeChapter = progress.chapter;
        _pageCount = progress.total;
      });
    }
    _visiblePage.value = progress.index;
    if (progress.key == _lastSavedKey ||
        progress.key == _pendingPosition?.key) return;
    _pendingPosition = progress;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600),
      () => unawaited(_flushPosition()));
  }

  Future<void> _flushPosition() {
    final pending = _pendingPosition;
    _pendingPosition = null;
    if (pending == null || pending.key == _lastSavedKey) return _saveChain;
    _lastSavedKey = pending.key;
    // Sequentialize writes even when the user passes a chapter boundary
    // before the debounce completes. Newer pages must not be overwritten
    // by an older, slower storage operation.
    _saveChain = _saveChain.then((_) => widget.library.savePosition(
      widget.book, pending.chapter, widget.sourceKey,
      pageIndex: pending.index, pageCount: pending.total,
    )).catchError((Object _) {});
    return _saveChain;
  }

  Future<void> _appendNextChapter() async {
    if (_nextLoading || _atSeriesEnd || _segments.isEmpty ||
        _nextError != null) return;
    setState(() => _nextLoading = true);
    try {
      if (_chapters.isEmpty) {
        final entry = widget.book.entries[widget.sourceKey];
        if (entry == null) throw StateError('Источник не найден');
        final detail = await widget.repository.sources[widget.sourceKey]!.detail(entry);
        if (!mounted) return;
        _chapters = detail.chapters;
      }
      // Only unambiguously numbered chapters can be advanced automatically.
      final ordered = _chapters.where((c) => canonicalChapterKey(c) != null)
          .toList()..sort((a, b) => compareChapterChronology(a, b)!);
      final currentId = _segments.last.chapter.id;
      final index = ordered.indexWhere((c) => c.id == currentId);
      if (index < 0 || index >= ordered.length - 1) {
        if (mounted) setState(() => _atSeriesEnd = true);
        return;
      }
      final next = ordered[index + 1];
      final pages = await widget.repository.sources[widget.sourceKey]!.pages(next);
      if (!mounted) return;
      if (pages.isEmpty) {
        setState(() => _nextError = 'Следующая глава пока недоступна');
        return;
      }
      setState(() => _segments.add(_ChapterSegment(next, pages)));
    } catch (_) {
      if (mounted) setState(() => _nextError = 'Не удалось загрузить следующую главу');
    } finally {
      if (mounted) setState(() => _nextLoading = false);
    }
  }

  @override void dispose() {
    _positions.itemPositions.removeListener(_onVisiblePages);
    _saveTimer?.cancel();
    unawaited(_flushPosition());
    _visiblePage.dispose();
    super.dispose();
  }

  Future<void> _mark() async {
    _saveTimer?.cancel();
    await _flushPosition();
    await widget.library.markRead(widget.book, _activeChapter, widget.sourceKey,
      availableChapters: _chapters);
  }

  Future<void> _go(Chapter chapter) async {
    if (chapter.id == _activeChapter.id) return;
    _saveTimer?.cancel();
    await _flushPosition();
    if (!mounted) return;
    await Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ReaderPage(
      book: widget.book, chapter: chapter, sourceKey: widget.sourceKey,
      repository: widget.repository, library: widget.library, chapters: _chapters,
    )));
  }

  Future<void> _chapterList() async {
    if (_loadingChapters) return;
    if (_chapters.isEmpty) {
      setState(() => _loadingChapters = true);
      try {
        final detail = await widget.repository.sources[widget.sourceKey]!
            .detail(widget.book.entries[widget.sourceKey]!);
        if (!mounted) return;
        setState(() { _chapters = detail.chapters; _loadingChapters = false; });
      } catch (_) {
        if (mounted) {
          setState(() => _loadingChapters = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не удалось получить список глав.')));
        }
        return;
      }
    }
    if (!mounted) return;
    final chapter = await showModalBottomSheet<Chapter>(context: context,
      useSafeArea: true, isScrollControlled: true,
      builder: (context) => SafeArea(child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(children: [
          const Padding(padding: EdgeInsets.all(16), child: Text('Главы')),
          Expanded(child: _chapters.isEmpty
            ? const Center(child: Text('Нет доступных глав'))
            : ListView.builder(itemCount: _chapters.length,
              itemBuilder: (context, index) => ListTile(
                selected: _chapters[index].id == _activeChapter.id,
                title: Text(_chapters[index].name),
                onTap: () => Navigator.pop(context, _chapters[index]),
              ))),
        ]),
      )));
    if (chapter != null && mounted) await _go(chapter);
  }

  Widget _toolbar() {
    final ordered = _chapters.where((chapter) => canonicalChapterKey(chapter) != null)
        .toList()..sort((a, b) => compareChapterChronology(a, b)!);
    final index = ordered.indexWhere((chapter) => chapter.id == _activeChapter.id);
    return Material(color: Theme.of(context).colorScheme.surface,
      child: SafeArea(top: false, child: Column(mainAxisSize: MainAxisSize.min, children: [
        ValueListenableBuilder<int>(valueListenable: _visiblePage,
          builder: (context, page, _) => Column(mainAxisSize: MainAxisSize.min, children: [
            if (_pageCount > 0) LinearProgressIndicator(
              value: (page.clamp(0, _pageCount - 1) + 1) / _pageCount),
            Row(children: [
              IconButton(tooltip: 'Список глав', onPressed: _loadingChapters ? null : _chapterList,
                icon: const Icon(Icons.format_list_bulleted)),
              IconButton(tooltip: 'Предыдущая глава',
                onPressed: index > 0 ? () => _go(ordered[index - 1]) : null,
                icon: const Icon(Icons.skip_previous_rounded)),
              Expanded(child: Text(_pageCount == 0 ? '—' :
                '${page.clamp(0, _pageCount - 1) + 1}/$_pageCount',
                maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center)),
              AnimatedBuilder(animation: widget.library, builder: (context, _) {
                final read = widget.library.isChapterRead(widget.book, _activeChapter, widget.sourceKey);
                return IconButton(tooltip: read ? 'Прочитано: отметить непрочитанной' : 'Отметить прочитанной',
                  onPressed: _pageCount == 0 ? null : () async {
                    if (read) {
                      final chapter = _activeChapter;
                      _manuallyUnreadChapters.add(chapter.id);
                      // Finish any queued automatic write before user's unread.
                      await _autoMarkChain;
                      await widget.library.unmarkRead(widget.book, chapter, widget.sourceKey,
                        availableChapters: _chapters);
                    } else {
                      _manuallyUnreadChapters.remove(_activeChapter.id);
                      await _mark();
                    }
                  },
                  icon: Icon(read ? Icons.visibility_outlined : Icons.visibility_off_outlined));
              }),
              IconButton(tooltip: 'Следующая глава',
                onPressed: index >= 0 && index + 1 < ordered.length
                    ? () => _go(ordered[index + 1]) : null,
                icon: const Icon(Icons.skip_next_rounded)),
            ]),
          ])),
      ])),
    );
  }

  @override Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Positioned.fill(child: LayoutBuilder(builder: (context, constraints) =>
          GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: (details) => _onCenterTap(details, constraints.biggest),
          child: FutureBuilder<List<PageImage>>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Padding(padding: const EdgeInsets.all(24),
              child: Text('Ошибка главы: ${snapshot.error}', style: const TextStyle(color: Colors.white))));
          }
          final pages = snapshot.data ?? [];
          if (pages.isEmpty) {
            return const Center(child: Padding(padding: EdgeInsets.all(24),
              child: Text('Нет доступных изображений. Возможно, глава удалена или доступ ограничен.', style: TextStyle(color: Colors.white))));
          }
          final initialIndex = _resumePage.clamp(0, pages.length - 1).toInt();
          return NotificationListener<ScrollNotification>(
            onNotification: (notice) {
              if (notice is ScrollUpdateNotification &&
                  (notice.scrollDelta ?? 0) > 0) {
                _hasForwardScrolled = true;
                // At the absolute bottom, the last image still occupies part
                // of the viewport above the footer. Requiring it to disappear
                // would make last-chapter auto-read impossible.
                _reachedScrollableEnd = notice.metrics.maxScrollExtent > 0 &&
                    notice.metrics.extentAfter <= 4;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _autoCompletePassedChapters(
                    _positions.itemPositions.value);
                });
              }
              return false;
            },
            child: ScrollablePositionedList.builder(
            key: ValueKey('${widget.sourceKey}:${widget.chapter.id}'),
            itemPositionsListener: _positions,
            initialScrollIndex: initialIndex,
            itemCount: _itemCount,
            itemBuilder: (context, index) {
              final heading = _headerChapterAt(index);
              if (heading != null) {
                return Container(
                  key: ValueKey('chapter-boundary-${heading.id}'),
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 22),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18, vertical: 24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF362016),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0xFFFF893F),
                      width: 1.5),
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.auto_stories_rounded,
                      color: Color(0xFFFFAC78), size: 30),
                    const SizedBox(height: 12),
                    const Text('СЛЕДУЮЩАЯ ГЛАВА',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFFFFAC78),
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5, fontSize: 12)),
                    const SizedBox(height: 8),
                    Text(heading.name, textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white,
                        fontWeight: FontWeight.w700, fontSize: 21)),
                    const SizedBox(height: 10),
                    const Icon(Icons.keyboard_double_arrow_down_rounded,
                      color: Color(0xFFFFAC78), size: 28),
                  ]),
                );
              }
              final item = _pageAt(index);
              if (item == null) {
                return Padding(padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (_nextLoading)
                      const CircularProgressIndicator()
                    else if (_nextError != null) ...[
                      Text(_nextError!, style: const TextStyle(color: Colors.white70)),
                      TextButton.icon(
                        onPressed: () {
                          setState(() => _nextError = null);
                          _appendNextChapter();
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('Повторить загрузку'),
                      ),
                    ] else if (_atSeriesEnd) ...[
                      const Text('Конец доступных глав',
                        style: TextStyle(color: Colors.white70)),
                      FilledButton.icon(onPressed: _mark,
                        icon: const Icon(Icons.check),
                        label: const Text('Отметить прочитанной')),
                    ] else
                      const Text('Следующая глава загружается при прокрутке',
                        style: TextStyle(color: Colors.white70)),
                  ]),
                );
              }
              final image = _segments.firstWhere(
                (segment) => segment.chapter.id == item.chapter.id
              ).pages[item.index];
              return Image.network(
                image.url,
                width: MediaQuery.sizeOf(context).width,
                headers: image.headers,
                fit: BoxFit.fitWidth,
                frameBuilder: (context, child, frame, wasSync) {
                  if (frame != null) _registerLoadedPage(item);
                  return frame == null
                    ? const SizedBox(height: 170,
                        child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
                    : child;
                },
                errorBuilder: (context, error, stack) => Container(
                  height: 170, color: Colors.white10, alignment: Alignment.center,
                  child: Text('Страница ${item.index + 1} не загрузилась',
                    style: const TextStyle(color: Colors.white60))),
              );
            },
          ));
        },
      ),
        ))),
        if (_controlsVisible)
          Positioned(top: 0, left: 0, right: 0,
            height: kToolbarHeight + MediaQuery.paddingOf(context).top,
            child: AppBar(
              backgroundColor: const Color(0xEE151317),
              foregroundColor: Colors.white,
              leading: IconButton(
                tooltip: 'Назад к произведению',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.maybePop(context),
              ),
              title: Text(_activeChapter.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            )),
        if (_controlsVisible)
          Positioned(bottom: 0, left: 0, right: 0, child: _toolbar()),
      ]),
    );
  }
}
