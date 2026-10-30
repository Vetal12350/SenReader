import 'dart:async';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../core/models.dart';
import '../core/chapter_identity.dart';
import '../data/catalog_repository.dart';
import '../data/library_store.dart';

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
  int? _lastSavedPage;
  int? _pendingPage;
  final ValueNotifier<int> _visiblePage = ValueNotifier(0);
  late List<Chapter> _chapters;
  bool _loadingChapters = false;
  // Distraction-free by default; users reveal controls with a central tap.
  bool _controlsVisible = false;
  void _onCenterTap(TapUpDetails details) {
    final size = MediaQuery.sizeOf(context);
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
    _visiblePage.value = _resumePage;
    future = widget.repository.sources[widget.sourceKey]!.pages(widget.chapter).then((pages) {
      if (mounted) setState(() => _pageCount = pages.length);
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

  void _onVisiblePages() {
    if (_pageCount == 0) return;
    final visible = _positions.itemPositions.value.where((position) =>
      position.index >= 0 && position.index < _pageCount &&
      position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    if (visible.isEmpty) return;
    final index = visible.first.index;
    _visiblePage.value = index;
    if (index == _lastSavedPage || index == _pendingPage) return;
    _pendingPage = index;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () => _storePosition(index));
  }

  Future<void> _storePosition(int page) async {
    if (_pageCount == 0 || page == _lastSavedPage) return;
    _pendingPage = null;
    _lastSavedPage = page;
    await widget.library.savePosition(widget.book, widget.chapter,
      widget.sourceKey, pageIndex: page, pageCount: _pageCount);
  }

  @override void dispose() {
    _positions.itemPositions.removeListener(_onVisiblePages);
    _saveTimer?.cancel();
    if (_pendingPage != null) {
      unawaited(_storePosition(_pendingPage!));
    }
    _visiblePage.dispose();
    super.dispose();
  }

  Future<void> _mark() async {
    _saveTimer?.cancel();
    if (_pendingPage != null) await _storePosition(_pendingPage!);
    await widget.library.markRead(widget.book, widget.chapter, widget.sourceKey,
      availableChapters: _chapters);
    // The eye marker updates immediately through LibraryStore listeners.
    // A snackbar would overlap the reader's bottom actions after marking.
  }

  Future<void> _go(Chapter chapter) async {
    if (chapter.id == widget.chapter.id) return;
    _saveTimer?.cancel();
    if (_pendingPage != null) await _storePosition(_pendingPage!);
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
                selected: _chapters[index].id == widget.chapter.id,
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
    final index = ordered.indexWhere((chapter) => chapter.id == widget.chapter.id);
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
                final read = widget.library.isChapterRead(widget.book, widget.chapter, widget.sourceKey);
                return IconButton(tooltip: read ? 'Прочитано: отметить непрочитанной' : 'Отметить прочитанной',
                  onPressed: _pageCount == 0 ? null : () async {
                    if (read) {
                      await widget.library.unmarkRead(widget.book, widget.chapter, widget.sourceKey);
                    } else {
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
        Positioned.fill(child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: _onCenterTap,
          child: FutureBuilder<List<PageImage>>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Padding(padding: const EdgeInsets.all(24),
              child: Text('Ошибка главы: ${snapshot.error}')));
          }
          final pages = snapshot.data ?? [];
          if (pages.isEmpty) {
            return const Center(child: Padding(padding: EdgeInsets.all(24),
              child: Text('Нет доступных изображений. Возможно, глава удалена или доступ ограничен.')));
          }
          final initialIndex = _resumePage.clamp(0, pages.length - 1).toInt();
          return ScrollablePositionedList.builder(
            key: ValueKey('${widget.sourceKey}:${widget.chapter.id}'),
            itemPositionsListener: _positions,
            initialScrollIndex: initialIndex,
            itemCount: pages.length + 1,
            itemBuilder: (context, index) {
              if (index == pages.length) {
                return Padding(padding: const EdgeInsets.all(24),
                  child: FilledButton.icon(onPressed: _mark,
                    icon: const Icon(Icons.check), label: const Text('Глава прочитана')));
              }
              return Image.network(
                pages[index].url,
                width: MediaQuery.sizeOf(context).width,
                headers: pages[index].headers,
                fit: BoxFit.fitWidth,
                frameBuilder: (context, child, frame, wasSync) => frame == null
                  ? const SizedBox(height: 170,
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
                  : child,
                errorBuilder: (context, error, stack) => Container(
                  height: 170, color: Colors.white10, alignment: Alignment.center,
                  child: Text('Страница ${index + 1} не загрузилась',
                    style: const TextStyle(color: Colors.white60))),
              );
            },
          );
        },
      ),
        )),
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
              title: Text(widget.chapter.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            )),
        if (_controlsVisible)
          Positioned(bottom: 0, left: 0, right: 0, child: _toolbar()),
      ]),
    );
  }
}
