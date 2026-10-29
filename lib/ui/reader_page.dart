import 'dart:async';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../core/models.dart';
import '../data/catalog_repository.dart';
import '../data/library_store.dart';

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.book, required this.chapter,
    required this.sourceKey, required this.repository, required this.library});
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

  @override void initState() {
    super.initState();
    future = widget.repository.sources[widget.sourceKey]!.pages(widget.chapter);
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
    super.dispose();
  }

  Future<void> _mark() async {
    _saveTimer?.cancel();
    if (_pendingPage != null) await _storePosition(_pendingPage!);
    await widget.library.markRead(widget.book, widget.chapter, widget.sourceKey);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Глава отмечена прочитанной')));
  }

  @override Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.chapter.name,
        maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [IconButton(tooltip: 'Отметить прочитанной',
          icon: const Icon(Icons.check_circle_outline), onPressed: _mark)]),
      backgroundColor: Colors.black,
      body: FutureBuilder<List<PageImage>>(
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
          _pageCount = pages.length;
          final initialIndex = _resumePage.clamp(0, pages.length - 1);
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
    );
  }
}
