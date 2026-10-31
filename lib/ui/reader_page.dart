import 'dart:async';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import '../main.dart' show mainTabRequest;
import '../core/models.dart';
import '../core/chapter_identity.dart';
import '../data/catalog_repository.dart';
import '../data/library_store.dart';
import '../data/reading_completion.dart';
import 'detail_page.dart';

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
  final ItemScrollController _itemScroll = ItemScrollController();
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
  bool _continuous = true;
  bool _fullScreen = false;
  bool _pageNumbers = true;
  bool _fitHeight = false;
  bool _lightTheme = false;
  double _brightness = 100;
  double _autoScrollSeconds = 5;
  Timer? _autoScrollTimer;

  Future<void> _restoreReaderSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _continuous = prefs.getBool('senreader.reader.continuous') ?? true;
      _pageNumbers = prefs.getBool('senreader.reader.page_numbers') ?? true;
      _fitHeight = prefs.getBool('senreader.reader.fit_height') ?? false;
      _lightTheme = prefs.getBool('senreader.reader.light_theme') ?? false;
      _brightness = (prefs.getDouble('senreader.reader.brightness') ?? 100).clamp(30.0, 100.0).toDouble();
      _autoScrollSeconds = (prefs.getDouble('senreader.reader.autoscroll') ?? 5).clamp(1.0, 12.0).toDouble();
    });
  }

  Future<void> _setReaderPref(String key, Object value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) await prefs.setBool('senreader.reader.' + key, value);
    if (value is double) await prefs.setDouble('senreader.reader.' + key, value);
  }

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
    unawaited(_restoreReaderSettings());
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
        if (pages.isNotEmpty) {
          // An opened chapter has an open eye immediately. Progress remains
          // independent so merely entering a page cannot skip the chapter.
          final page = _resumePage.clamp(0, pages.length - 1).toInt();
          final initial = _VisibleChapterPage(widget.chapter, page, pages.length);
          if (_lastSavedKey == null && _pendingPosition == null) {
            _lastSavedKey = initial.key;
            _saveChain = _saveChain.then((_) async {
              await widget.library.savePosition(widget.book, widget.chapter,
                widget.sourceKey, pageIndex: page, pageCount: pages.length);
              await widget.library.markRead(widget.book, widget.chapter,
                widget.sourceKey, availableChapters: _chapters);
              await widget.library.recordLatestChapter(
                widget.book, widget.sourceKey, _chapters);
            }).catchError((Object _) {});
          } else {
            unawaited(widget.library.markRead(widget.book, widget.chapter,
              widget.sourceKey, availableChapters: _chapters));
          }
        }
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
      // Scroll callbacks fire for every small movement. Most of the time no
      // chapter boundary has been crossed; avoid rebuilding loaded-page sets.
      if (_autoCompletedChapters.contains(segment.chapter.id) ||
          _manuallyUnreadChapters.contains(segment.chapter.id)) {
        endIndex++;
        continue;
      }
      final passed = i < _segments.length - 1
          ? previousChapterBoundaryReached(
              boundaryIndex: endIndex,
              visibleItemIndexes: visible.map((item) => item.index))
          : terminalChapterBoundaryReached(
              forwardScrolled: _hasForwardScrolled,
              reachedScrollableEnd: _reachedScrollableEnd,
              footerVisible: visible.any((item) => item.index == _itemCount - 1));
      if (!passed) {
        endIndex++;
        continue;
      }
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
    if (!_continuous) { if (mounted) setState(() => _atSeriesEnd = true); return; }
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
    _autoScrollTimer?.cancel();
    if (_fullScreen) unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
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

  Future<void> _toggleRead() async {
    final chapter = _activeChapter;
    if (widget.library.isChapterRead(widget.book, chapter, widget.sourceKey)) {
      _manuallyUnreadChapters.add(chapter.id);
      await _autoMarkChain;
      await widget.library.unmarkRead(widget.book, chapter, widget.sourceKey,
        availableChapters: _chapters);
    } else {
      _manuallyUnreadChapters.remove(chapter.id);
      await _mark();
    }
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
                title: Text(displayChapterName(_chapters[index].name)),
                onTap: () => Navigator.pop(context, _chapters[index]),
              ))),
        ]),
      )));
    if (chapter != null && mounted) await _go(chapter);
  }

  int? _itemIndexForPage(Chapter chapter, int page) {
    var index = 0;
    for (var i = 0; i < _segments.length; i++) {
      if (i > 0) index++; // Chapter boundary.
      final segment = _segments[i];
      if (segment.chapter.id == chapter.id) {
        if (page < 0 || page >= segment.pages.length) return null;
        return index + page;
      }
      index += segment.pages.length;
    }
    return null;
  }

  void _stepPage(int delta) {
    if (!_itemScroll.isAttached || _pageCount == 0) return;
    final next = _visiblePage.value + delta;
    if (next < 0 || next >= _pageCount) return;
    final index = _itemIndexForPage(_activeChapter, next);
    if (index == null) return;
    unawaited(_itemScroll.scrollTo(index: index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut));
  }

  void _openTitle() {
    _saveTimer?.cancel();
    unawaited(_flushPosition());
    Navigator.push(context, MaterialPageRoute(builder: (_) => DetailPage(
      book: widget.book, repository: widget.repository, library: widget.library,
    )));
  }


  Future<void> _stepChapter(int delta) async {
    if (_chapters.isEmpty) {
      try {
        final entry = widget.book.entries[widget.sourceKey];
        if (entry == null) return;
        final info = await widget.repository.sources[widget.sourceKey]!.detail(entry);
        if (!mounted) return;
        _chapters = info.chapters;
      } catch (_) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось загрузить главы')));
        return;
      }
    }
    final ordered = _chapters.where((e) => canonicalChapterKey(e) != null)
      .toList()..sort((a, b) => compareChapterChronology(a, b)!);
    final at = ordered.indexWhere((e) => e.id == _activeChapter.id);
    if (at < 0 || at + delta < 0 || at + delta >= ordered.length) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Других доступных глав нет')));
      return;
    }
    await _go(ordered[at + delta]);
  }

  void _jumpPage(int index) {
    final itemIndex = _itemIndexForPage(_activeChapter, index);
    if (itemIndex != null && _itemScroll.isAttached) {
      _itemScroll.jumpTo(index: itemIndex);
    }
  }

  void _goToRoot(int destination) {
    _saveTimer?.cancel();
    unawaited(_flushPosition());
    mainTabRequest.value = destination;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _exitMenu() {
    // Compact anchored menu, modeled after Senkuro's back arrow.
    final width = MediaQuery.sizeOf(context).width;
    final top = MediaQuery.paddingOf(context).top + kToolbarHeight + 8;
    showMenu<int>(context: context,
      position: RelativeRect.fromLTRB(16, top,
        (width - 240).clamp(0.0, width).toDouble(), 0),
      constraints: const BoxConstraints(maxWidth: 245),
      items: const [
        PopupMenuItem(value: 0, child: ListTile(
          dense: true, leading: Icon(Icons.home_outlined), title: Text('Главная'))),
        PopupMenuItem(value: 3, child: ListTile(
          dense: true, leading: Icon(Icons.notifications_outlined),
          title: Text('Уведомления'))),
        PopupMenuItem(value: 2, child: ListTile(
          dense: true, leading: Icon(Icons.bookmarks_outlined),
          title: Text('Закладки'))),
      ],
    ).then((destination) {
      if (destination != null && mounted) _goToRoot(destination);
    });
  }

  void _toggleAutoscroll() {
    if (_autoScrollTimer != null) {
      _autoScrollTimer!.cancel();
      setState(() => _autoScrollTimer = null);
    } else {
      setState(() => _autoScrollTimer = Timer.periodic(
        Duration(milliseconds: (_autoScrollSeconds * 1000).round()),
        (timer) {
          if (!mounted || _visiblePage.value >= _pageCount - 1) {
            timer.cancel();
            if (mounted) setState(() => _autoScrollTimer = null);
            return;
          }
          _stepPage(1);
        }));
    }
  }

  void _readerSettings() {
    showModalBottomSheet<void>(context: context, isScrollControlled: true,
      useSafeArea: true, builder: (sheet) => StatefulBuilder(
        builder: (sheet, localSet) {
          void update(void Function() change, String key, Object value) {
            setState(change);
            localSet(() {});
            unawaited(_setReaderPref(key, value));
          }
          return FractionallySizedBox(heightFactor: 0.83,
            child: ListView(padding: const EdgeInsets.all(18), children: [
              Row(children: [
                const Expanded(child: Text('Настройки читалки',
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold))),
                IconButton(tooltip: 'Закрыть', onPressed: () => Navigator.pop(sheet),
                  icon: const Icon(Icons.close)),
              ]),
              const SizedBox(height: 10),
              SwitchListTile(title: const Text('Все главы подряд'),
                value: _continuous, onChanged: (v) => update(
                  () => _continuous = v, 'continuous', v)),
              SwitchListTile(title: const Text('Нумерация страниц'),
                value: _pageNumbers, onChanged: (v) => update(
                  () => _pageNumbers = v, 'page_numbers', v)),
              SwitchListTile(title: const Text('Полноэкранный режим'),
                value: _fullScreen, onChanged: (v) {
                  setState(() => _fullScreen = v);
                  localSet(() {});
                  unawaited(SystemChrome.setEnabledSystemUIMode(
                    v ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge));
                }),
              const ListTile(title: Text('Тема')),
              SegmentedButton<bool>(segments: const [
                ButtonSegment(value: false, label: Text('Тёмная')),
                ButtonSegment(value: true, label: Text('Светлая'))],
                selected: {_lightTheme},
                onSelectionChanged: (v) => update(() => _lightTheme = v.first,
                  'light_theme', v.first)),
              const ListTile(title: Text('Вмещать изображения')),
              SegmentedButton<bool>(segments: const [
                ButtonSegment(value: false, label: Text('По ширине')),
                ButtonSegment(value: true, label: Text('По высоте'))],
                selected: {_fitHeight},
                onSelectionChanged: (v) => update(() => _fitHeight = v.first,
                  'fit_height', v.first)),
              ListTile(title: Text('Яркость изображений: ' +
                  _brightness.round().toString() + '%')),
              Slider(min: 30, max: 100, divisions: 14, value: _brightness,
                onChanged: (v) => update(() => _brightness = v, 'brightness', v)),
              ListTile(title: Text('Скорость автопрокрутки: ' +
                  _autoScrollSeconds.round().toString() + ' сек./стр.')),
              Slider(min: 1, max: 12, divisions: 11, value: _autoScrollSeconds,
                onChanged: (v) => update(() => _autoScrollSeconds = v,
                  'autoscroll', v)),
              const ListTile(
                title: Text('Показать оригинал'),
                subtitle: Text('Недоступно: источник не предоставляет альтернативное изображение'),
                enabled: false),
            ]));
        }));
  }


  Widget _toolbar() {
    return Material(color: const Color(0xEE19171A),
      child: SafeArea(top: false, child: Column(
        mainAxisSize: MainAxisSize.min, children: [
        ValueListenableBuilder<int>(valueListenable: _visiblePage,
          builder: (context, page, _) => Column(mainAxisSize: MainAxisSize.min,
            children: [
              if (_pageCount > 0) LinearProgressIndicator(
                value: (page.clamp(0, _pageCount - 1) + 1) / _pageCount),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                IconButton(tooltip: 'Предыдущая глава',
                  onPressed: () => _stepChapter(-1),
                  icon: const Icon(Icons.chevron_left_rounded)),
                IconButton(tooltip: 'Список глав',
                  onPressed: _loadingChapters ? null : _chapterList,
                  icon: const Icon(Icons.format_list_bulleted)),
                IconButton(tooltip: 'Настройки читалки',
                  onPressed: _readerSettings,
                  icon: const Icon(Icons.settings_outlined)),
                if (_pageCount > 0 && _pageNumbers)
                  PopupMenuButton<int>(tooltip: 'Выбрать страницу',
                    key: const Key('reader-page-picker'),
                    constraints: BoxConstraints(minWidth: 150, maxWidth: 180,
                      maxHeight: MediaQuery.sizeOf(context).height * 0.30),
                    initialValue: page.clamp(0, _pageCount - 1),
                    onSelected: _jumpPage,
                    itemBuilder: (_) => [
                      const PopupMenuItem<int>(enabled: false,
                        height: 40, child: Text('№ страницы',
                          style: TextStyle(fontWeight: FontWeight.bold))),
                      for (var i = 0; i < _pageCount; i++)
                        PopupMenuItem(value: i, height: 42,
                          child: Text('${i + 1} страница')),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9, vertical: 7),
                      decoration: BoxDecoration(
                        color: const Color(0xFF30251F),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: Colors.white24)),
                      child: Text('${page.clamp(0, _pageCount - 1) + 1}/$_pageCount',
                        style: const TextStyle(fontWeight: FontWeight.bold,
                          fontSize: 12, color: Colors.white)),
                    ),
                  )
                else const SizedBox(width: 8),
                IconButton(tooltip: _autoScrollTimer == null
                    ? 'Автопрокрутка' : 'Остановить автопрокрутку',
                  onPressed: _pageCount > 0 ? _toggleAutoscroll : null,
                  icon: Icon(_autoScrollTimer == null
                    ? Icons.play_circle_outline : Icons.pause_circle_outline)),
                IconButton(tooltip: 'Следующая глава',
                  onPressed: () => _stepChapter(1),
                  icon: const Icon(Icons.chevron_right_rounded)),
              ]),
            ])),
      ])),
    );
  }

  @override Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _lightTheme ? Colors.white : Colors.black,
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
            itemScrollController: _itemScroll,
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
                    Text(displayChapterName(heading.name), textAlign: TextAlign.center,
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
              return ColorFiltered(colorFilter: ColorFilter.mode(
                Colors.black.withValues(alpha: (100 - _brightness) / 100),
                BlendMode.srcATop), child: Image.network(
                image.url,
                width: MediaQuery.sizeOf(context).width,
                headers: image.headers,
                fit: _fitHeight ? BoxFit.contain : BoxFit.fitWidth,
                height: _fitHeight ? MediaQuery.sizeOf(context).height : null,
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
              ));
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
                tooltip: 'Выход из главы',
                icon: const Icon(Icons.arrow_back),
                onPressed: _exitMenu,
              ),
              title: InkWell(
                key: const Key('reader-open-title'),
                onTap: _openTitle,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min, children: [
                    Text(widget.book.title, maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16,
                        fontWeight: FontWeight.w700)),
                    Text(displayChapterName(_activeChapter.name), maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12)),
                  ]),
              ),
              actions: [
                AnimatedBuilder(animation: widget.library, builder: (context, _) {
                  final read = widget.library.isChapterRead(widget.book,
                    _activeChapter, widget.sourceKey);
                  return IconButton(tooltip: read ? 'Прочитано' : 'Отметить прочитанной',
                    onPressed: _toggleRead, icon: Icon(read
                      ? Icons.bookmark_added_outlined : Icons.bookmark_add_outlined));
                }),
                IconButton(tooltip: 'Страница тайтла',
                  onPressed: _openTitle,
                  icon: const Icon(Icons.info_outline_rounded)),
              ],
            )),
        if (_controlsVisible)
          Positioned(bottom: 0, left: 0, right: 0, child: _toolbar()),
      ]),
    );
  }
}
