import 'dart:async';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import '../main.dart' show mainTabRequest;
import '../core/models.dart';
import '../core/chapter_identity.dart';
import '../data/catalog_repository.dart';
import '../data/page_load_retry.dart';
import '../data/library_store.dart';
import '../data/reading_completion.dart';
import 'detail_page.dart';
import 'reader_prefetch_policy.dart';
import 'reader_frame_metrics.dart';

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


/// A failed CDN image is retried in place rather than requiring route
/// navigation. Keep its state tied to the chapter/page, not viewport rebuilds.
/// Decode at screen resolution rather than full remote image resolution.
/// 1600 physical pixels retains detail on high-density Android displays.
int readerDecodeWidth(double logicalWidth, double pixelRatio) =>
    (logicalWidth * pixelRatio).ceil().clamp(1, 1600).toInt();

/// Reserve the actual aspect-ratio height before an upcoming webtoon page
/// enters the viewport. The decoded size may be smaller than its CDN original.
double? readerLogicalImageHeight(
    double logicalWidth, int decodedWidth, int decodedHeight) {
  if (!logicalWidth.isFinite || logicalWidth <= 0 ||
      decodedWidth <= 0 || decodedHeight <= 0) return null;
  final height = logicalWidth * decodedHeight / decodedWidth;
  if (!height.isFinite || height <= 0 || height > 50000) return null;
  return height;
}

class _RetryableReaderImage extends StatefulWidget {
  const _RetryableReaderImage({super.key, required this.page,
    required this.pageIndex, required this.width,
    required this.height, required this.fit, required this.onLoaded,
    required this.onRefreshLinks, required this.decodeWidth,
    this.imageProvider,
    required this.knownHeight, required this.onMeasuredHeight});
  final PageImage page;
  final int pageIndex;
  final double width;
  final double? height;
  final BoxFit fit;
  final int decodeWidth;
  final ImageProvider? imageProvider;
  final double? knownHeight;
  final ValueChanged<double> onMeasuredHeight;
  final VoidCallback onLoaded;
  final Future<void> Function() onRefreshLinks;

  @override State<_RetryableReaderImage> createState() =>
      _RetryableReaderImageState();
}

class _RetryableReaderImageState extends State<_RetryableReaderImage> {
  int _attempt = 0;
  Timer? _retryTimer;
  bool _measured = false;

  void _retry(ImageProvider image) {
    _retryTimer?.cancel();
    _retryTimer = null;
    // Evict any failed network image from Flutter's image cache.
    unawaited(() async {
      await image.evict();
      if (mounted) setState(() => _attempt++);
    }());
  }

  void _scheduleRetry(ImageProvider image) {
    if (_attempt >= 2 || _retryTimer != null) return;
    _retryTimer = Timer(
      Duration(milliseconds: _attempt == 0 ? 450 : 1100),
      () => _retry(image),
    );
  }

  @override void didUpdateWidget(_RetryableReaderImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page.url != widget.page.url) {
      _retryTimer?.cancel();
      _retryTimer = null;
      _attempt = 0;
      _measured = false;
    }
  }

  @override void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  @override Widget build(BuildContext context) {
    final provider = widget.imageProvider ?? ResizeImage.resizeIfNeeded(widget.decodeWidth, null,
      NetworkImage(widget.page.url, headers: widget.page.headers));
    return Semantics(image: true, label: 'Страница ${widget.pageIndex + 1}', child: Image(
      key: ValueKey('reader-image-attempt-$_attempt'),
      image: provider, width: widget.width, excludeFromSemantics: true,
      height: widget.height ?? widget.knownHeight,
      alignment: widget.height == null ? Alignment.topCenter : Alignment.center,
      fit: widget.fit, filterQuality: FilterQuality.low,
      frameBuilder: (context, child, frame, wasSync) {
        if (frame != null) {
          widget.onLoaded();
          if (!_measured && widget.height == null && child is RawImage) {
            final bitmap = child.image;
            final measured = bitmap == null ? null : readerLogicalImageHeight(
              widget.width, bitmap.width, bitmap.height);
            if (measured != null) {
              _measured = true;
              widget.onMeasuredHeight(measured);
            }
          }
          // Keep the old box until the geometry coordinator can safely commit
          // the ratio. A late image above the viewport must not move content.
          return SizedBox(height: widget.height ?? widget.knownHeight ?? widget.width * 1.5,
            child: ClipRect(child: child));
        }
        // Preserve the previous layout when the image cache evicts a bitmap.
        // The former fixed 170px tile caused scroll corrections on return.
        return SizedBox(
          height: widget.height ?? widget.knownHeight ?? widget.width * 1.5,
          child: const Center(
            child: CircularProgressIndicator(strokeWidth: 2)));
      },
      errorBuilder: (context, error, stack) {
        _scheduleRetry(provider);
        return Container(
          height: widget.height ?? widget.knownHeight ?? widget.width * 1.5,
          color: Colors.white10,
          alignment: Alignment.center,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Страница ${widget.pageIndex + 1} не загрузилась',
              style: const TextStyle(color: Colors.white60)),
            const SizedBox(height: 8),
            TextButton.icon(onPressed: () => _retry(provider),
              icon: const Icon(Icons.refresh),
              label: const Text('Повторить')),
            if (_attempt >= 2)
              TextButton(onPressed: () => unawaited(widget.onRefreshLinks()),
                child: const Text('Обновить ссылки главы')),
          ]),
        );
      },
    ));
  }
}

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.book, required this.chapter,
    required this.sourceKey, required this.repository, required this.library,
    this.chapters = const [], this.imageProviderFactory});
  @visibleForTesting
  final ImageProvider Function(PageImage, int)? imageProviderFactory;
  final List<Chapter> chapters;
  final UnifiedManga book;
  final Chapter chapter;
  final String sourceKey;
  final CatalogRepository repository;
  final LibraryStore library;
  @override State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> with WidgetsBindingObserver {
  late Future<List<PageImage>> future;
  // Profile identity is fixed for the lifetime of this route, including
  // delayed page loading, debounced position writes and disposal.
  late final String _readerProfile;
  bool get _sessionActive => widget.library.profileId == _readerProfile;
  final ItemPositionsListener _positions = ItemPositionsListener.create();
  final ItemScrollController _itemScroll = ItemScrollController();
  // Pixel-relative scrolling keeps movement smooth across tall webtoon images.
  final ScrollOffsetController _scrollOffset = ScrollOffsetController();
  Timer? _saveTimer;
  int _pageCount = 0;
  String? _lastSavedKey;
  _VisibleChapterPage? _pendingPosition;
  Future<void> _saveChain = Future<void>.value();
  final List<_ChapterSegment> _segments = [];
  final Set<String> _loadedPageKeys = {};
  final Set<String> _loadingPageKeys = {};
  // Aspect ratios outlive bitmap cache entries and do not depend on viewport
  // width. Lightweight route-local metadata is retained for every loaded page.
  final Map<String, ValueNotifier<double?>> _pageRatios = {};
  final Map<String, double> _pendingRatios = {};
  bool _geometryCommitScheduled = false;
  final Map<String, VoidCallback> _geometryProbes = {};
  final Map<String, int> _geometryProbeEpochs = {};
  final Map<String, DateTime> _geometryRetryAt = {};
  final List<int> _geometryCandidates = [];
  final Set<String> _geometryAttempted = {};
  String? _geometryWindow;
  int _geometryEpoch = 0;
  bool _scrollMoving = false, _forward = true, _memoryPressure = false;
  double _velocity = 0, _layoutWidth = 0;
  final Stopwatch _motionClock = Stopwatch()..start();
  int _lastMotionUs = 0;
  double? _lastGeometryViewportWidth;
  ReaderFrameMetrics? _frameMetrics;
  int? _lastCompletionVisibleIndex;
  final Map<String, int> _chapterReloads = {};
  final Set<String> _refreshingChapterLinks = {};
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
  bool _autoScrolling = false;
  int _autoScrollRun = 0;
  bool _autoAtBottom = false;

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
    WidgetsBinding.instance.addObserver(this);
    _readerProfile = widget.library.profileId;
    unawaited(_restoreReaderSettings());
    _chapters = widget.chapters;
    _activeChapter = widget.chapter;
    _visiblePage.value = _resumePage;
    future = _loadInitialChapter();
    _positions.itemPositions.addListener(_onVisiblePages);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final width = MediaQuery.sizeOf(context).width;
    if (_lastGeometryViewportWidth != null &&
        _lastGeometryViewportWidth != width) {
      // Ratios survive rotation; only speculative decoder targets change.
      _geometryCandidates.clear();
      _geometryAttempted.clear();
      _geometryWindow = null;
    }
    _lastGeometryViewportWidth = width;
    if (const bool.fromEnvironment('SENREADER_READER_TRACE') && _frameMetrics == null) {
      final hz = View.of(context).display.refreshRate;
      const configured = int.fromEnvironment('SENREADER_FRAME_BUDGET_US');
      _frameMetrics = ReaderFrameMetrics(configured > 0 ? configured :
        (1000000 / (hz > 0 ? hz : 60)).round())..start();
    }
  }

  Future<List<PageImage>> _loadInitialChapter() async {
    final pages = await loadChapterPagesWithRetry(
      widget.repository.sources[widget.sourceKey]!, widget.chapter);
      if (mounted && _sessionActive) {
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
              if (!_sessionActive) return;
              await widget.library.savePosition(widget.book, widget.chapter,
                widget.sourceKey, pageIndex: page, pageCount: pages.length,
                expectedProfile: _readerProfile);
              await widget.library.markRead(widget.book, widget.chapter,
                widget.sourceKey, availableChapters: _chapters,
                expectedProfile: _readerProfile);
              await widget.library.recordLatestChapter(
                widget.book, widget.sourceKey, _chapters,
                expectedProfile: _readerProfile);
            }).catchError((Object _) {});
          } else {
            unawaited(widget.library.markRead(widget.book, widget.chapter,
              widget.sourceKey, availableChapters: _chapters,
              expectedProfile: _readerProfile));
          }
        }
      }
    return pages;
  }

  void _retryInitialChapter() {
    if (!mounted) return;
    _stopAutoScroll();
    _cancelGeometryProbes();
    _pendingRatios.clear();
    _geometryRetryAt.clear();
    _geometryWindow = null;
    setState(() {
      // The failed future is never reused; no need to reopen the route.
      _segments.clear();
      _loadedPageKeys.clear();
      _atSeriesEnd = false;
      _nextError = null;
      future = _loadInitialChapter();
    });
  }

  int get _resumePage {
    if (!_sessionActive) return 0;
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
    if (!_sessionActive || !_hasForwardScrolled || _segments.isEmpty) return;
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
            availableChapters: _chapters, expectedProfile: _readerProfile);
        }).catchError((Object _) {
          // A failed persistence write must not permanently suppress a retry.
          _autoCompletedChapters.remove(chapter.id);
        });
      }
      endIndex++; // Chapter separator (or terminal footer).
    }
  }

  void _registerLoadedPage(_VisibleChapterPage item) {
    if (_loadedPageKeys.contains(item.key) ||
        !_loadingPageKeys.add(item.key)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadingPageKeys.remove(item.key);
      if (!mounted) return;
      _loadedPageKeys.add(item.key);
      _autoCompletePassedChapters(_positions.itemPositions.value);
    });
  }

  ValueNotifier<double?> _ratioFor(String key) =>
      _pageRatios.putIfAbsent(key, () => ValueNotifier<double?>(null));

  void _rememberHeight(String key, double height, {required double width}) {
    if (!height.isFinite || height <= 0 || width <= 0) return;
    final ratio = height / width;
    final known = _ratioFor(key).value;
    if ((known != null && ((known - ratio) * width).abs() < 1) ||
        _pendingRatios[key] == ratio) return;
    _geometryRetryAt.remove(key);
    _pendingRatios[key] = ratio;
    _scheduleGeometryCommit();
  }

  void _scheduleGeometryCommit() {
    if (_geometryCommitScheduled || _pendingRatios.isEmpty) return;
    _geometryCommitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _geometryCommitScheduled = false;
      if (mounted) _commitGeometry();
    });
  }

  int? _geometryIndex(String key) {
    final separator = key.lastIndexOf('|');
    if (separator < 0) return null;
    final chapter = key.substring(0, separator);
    final page = int.tryParse(key.substring(separator + 1));
    if (page == null || page < 0) return null;
    var offset = 0;
    for (var i = 0; i < _segments.length; i++) {
      if (i > 0) offset++;
      final segment = _segments[i];
      if (segment.chapter.id == chapter) {
        return page < segment.pages.length ? offset + page : null;
      }
      offset += segment.pages.length;
    }
    return null;
  }

  void _commitGeometry() {
    if (_pendingRatios.isEmpty) return;
    final visible = _positions.itemPositions.value.where((p) =>
      p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1 && _pageAt(p.index) != null)
        .toList()..sort((a,b) => a.index.compareTo(b.index));
    // Prefer already decoded content, not an unknown loading box above it.
    final known = visible.where((p) =>
      _pageRatios[_pageAt(p.index)!.key]?.value != null).toList();
    final anchor = known.where((p) => p.itemLeadingEdge >= 0).firstOrNull ??
        known.firstOrNull ?? visible.firstOrNull;
    var correctAnchor = false;
    final pending = Map<String, double>.from(_pendingRatios);
    _pendingRatios.clear();
    for (final entry in pending.entries) {
      final index = _geometryIndex(entry.key);
      if (index == null) continue;
      final beforeAnchor = anchor != null && index < anchor.index;
      if (beforeAnchor && (_scrollMoving || _autoScrolling)) {
        // jumpTo cancels a fling/gesture. Defer only changes that would move
        // the visible anchor, not images ahead of the reader.
        _pendingRatios[entry.key] = entry.value;
        continue;
      }
      _ratioFor(entry.key).value = entry.value;
      correctAnchor |= beforeAnchor;
      _frameMetrics?.geometryCommitted();
    }
    if (correctAnchor && anchor != null && _itemScroll.isAttached) {
      _itemScroll.jumpTo(index: anchor.index, alignment: anchor.itemLeadingEdge);
      _frameMetrics?.anchorCorrected();
    }
  }

  @override void didHaveMemoryPressure() {
    _memoryPressure = true;
    _geometryCandidates.clear();
    _geometryWindow = null;
    // Geometry is tiny and must survive eviction; do not clear global caches
    // or retry all CDN images in response to a pressure notification.
  }

  void _cancelGeometryProbes() {
    _geometryEpoch++;
    for (final cancel in _geometryProbes.values.toList()) { cancel(); }
    _geometryProbes.clear();
    _geometryProbeEpochs.clear();
    _geometryCandidates.clear();
    _geometryAttempted.clear();
  }

  void _invalidateGeometryProbes() {
    _geometryEpoch++;
    _geometryCandidates.clear();
    _geometryAttempted.clear();
    // Keep obsolete in-flight slots charged until terminal completion. A
    // refreshed URL must not multiply speculative HTTP requests behind us.
  }

  void _preloadUpcomingGeometry(int first, int last) {
    if (!mounted || _fitHeight) return;
    final viewport = MediaQuery.sizeOf(context).height;
    final cache = PaintingBinding.instance.imageCache;
    final signature = '$first:$last:$_itemCount:$_forward:${_velocity.abs() > viewport}:$_memoryPressure';
    if (signature != _geometryWindow) {
      _geometryWindow = signature;
      _geometryAttempted.clear();
      _geometryCandidates
        ..clear()
        ..addAll(ReaderPrefetchPolicy.candidates(first: first, last: last,
          count: _itemCount, forward: _forward, velocity: _velocity,
          viewport: viewport, memoryPressure: _memoryPressure));
    }
    _frameMetrics?.sampleCache(cache.currentSizeBytes);
    _pumpGeometry();
  }

  void _pumpGeometry() {
    if (!mounted || _fitHeight) return;
    final cache = PaintingBinding.instance.imageCache;
    final limit = ReaderPrefetchPolicy.concurrency(cache.currentSizeBytes,
      cache.maximumSizeBytes, memoryPressure: _memoryPressure);
    final width = _layoutWidth > 0 ? _layoutWidth : MediaQuery.sizeOf(context).width;
    final decodeWidth = readerDecodeWidth(width, MediaQuery.devicePixelRatioOf(context));
    while (_geometryProbes.length < limit && _geometryCandidates.isNotEmpty) {
      final item = _pageAt(_geometryCandidates.removeAt(0));
      if (item == null || _geometryProbes.containsKey(item.key) ||
          !_geometryAttempted.add(item.key) ||
          (_geometryRetryAt[item.key]?.isAfter(DateTime.now()) ?? false)) continue;
      final ratio = _pageRatios[item.key]?.value;
      // Do not speculatively decode a known giant bitmap or displace the
      // visible working set. Visible images retain the original decode quality.
      if (ratio != null && ReaderPrefetchPolicy.decodedBytes(decodeWidth, ratio) >
          cache.maximumSizeBytes ~/ 3) continue;
      final segment = _segments.firstWhere((s) => s.chapter.id == item.chapter.id);
      final page = segment.pages[item.index];
      final provider = widget.imageProviderFactory?.call(page, decodeWidth) ??
        ResizeImage.resizeIfNeeded(decodeWidth, null,
          NetworkImage(page.url, headers: page.headers));
      final epoch = _geometryEpoch;
      final stream = provider.resolve(createLocalImageConfiguration(context));
      late ImageStreamListener listener;
      Timer? deadline;
      void finish() {
        deadline?.cancel();
        stream.removeListener(listener);
        if (_geometryProbeEpochs[item.key] == epoch) {
          _geometryProbes.remove(item.key);
          _geometryProbeEpochs.remove(item.key);
        }
      }
      void next() { scheduleMicrotask(() {
        if (mounted) _pumpGeometry();
      }); }
      listener = ImageStreamListener((info, _) {
        try {
          if (mounted && epoch == _geometryEpoch) {
            final height = readerLogicalImageHeight(width, info.image.width, info.image.height);
            if (height != null) _rememberHeight(item.key, height, width: width);
          }
        } finally {
          // Each listener owns an ImageInfo clone. Geometry never owns pixels.
          info.dispose();
          finish();
          next();
        }
      }, onError: (error, stack) {
        if (mounted && epoch == _geometryEpoch) {
          _geometryRetryAt[item.key] = DateTime.now().add(const Duration(seconds: 30));
        }
        finish(); next();
      });
      deadline = Timer(const Duration(seconds: 12), () {
        _geometryRetryAt[item.key] = DateTime.now().add(const Duration(seconds: 30));
        // NetworkImage listener removal does not abort HTTP. Keep the slot
        // charged until the transport actually finishes: no timeout-driven
        // burst of new speculative downloads. Visible loading is independent.
      });
      _geometryProbes[item.key] = finish;
      _geometryProbeEpochs[item.key] = epoch;
      stream.addListener(listener);
    }
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

    // Prepare the next images' real aspect ratios rather than discovering
    // their heights during a swipe and forcing a scroll layout correction.
    final firstIndex = visible.isEmpty ? null : visible.first.index;
    if (firstIndex != null) {
      final lastIndex = visible.last.index;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _preloadUpcomingGeometry(firstIndex, lastIndex);
      });
    }

    // A full completion scan on every pixel of a long image can trigger
    // expensive work while dragging. Run it when a new item enters view.
    if (firstIndex != _lastCompletionVisibleIndex) {
      _lastCompletionVisibleIndex = firstIndex;
      _autoCompletePassedChapters(visible);
    }
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
      expectedProfile: _readerProfile,
    )).catchError((Object _) {});
    return _saveChain;
  }

  /// Refresh potentially expired image URLs without leaving the chapter or
  /// rewriting the reader's saved position, manual eyes, or chapter status.
  Future<void> _refreshChapterImages(Chapter chapter) async {
    if (!_refreshingChapterLinks.add(chapter.id)) return;
    try {
      final pages = await loadChapterPagesWithRetry(
        widget.repository.sources[widget.sourceKey]!, chapter);
      if (!mounted || pages.isEmpty) return;
      final index = _segments.indexWhere((part) => part.chapter.id == chapter.id);
      if (index < 0) return;
      setState(() {
        _segments[index] = _ChapterSegment(chapter, pages);
        _chapterReloads[chapter.id] = (_chapterReloads[chapter.id] ?? 0) + 1;
        if (_activeChapter.id == chapter.id) _pageCount = pages.length;
        _loadedPageKeys.removeWhere((key) => key.startsWith('${chapter.id}|'));
        _loadingPageKeys.removeWhere((key) => key.startsWith('${chapter.id}|'));
        // Expiring signed/CDN URLs do not change page geometry. Retain ratios
        // by chapter/page until the refreshed image proves a different size.
        _geometryRetryAt.removeWhere((key, _) => key.startsWith('${chapter.id}|'));
        _geometryWindow = null;
      });
      _invalidateGeometryProbes();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
          content: Text('Не удалось обновить ссылки. Попробуйте ещё раз.')));
      }
    } finally {
      _refreshingChapterLinks.remove(chapter.id);
    }
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
      final pages = await loadChapterPagesWithRetry(
        widget.repository.sources[widget.sourceKey]!, next);
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
    WidgetsBinding.instance.removeObserver(this);
    _cancelGeometryProbes();
    for (final ratio in _pageRatios.values) { ratio.dispose(); }
    _frameMetrics?.stop();
    _stopAutoScroll(updateUi: false);
    if (_fullScreen) unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    _saveTimer?.cancel();
    unawaited(_flushPosition());
    _visiblePage.dispose();
    super.dispose();
  }

  Future<void> _mark() async {
    if (!_sessionActive) return;
    _saveTimer?.cancel();
    await _flushPosition();
    await widget.library.markRead(widget.book, _activeChapter, widget.sourceKey,
      availableChapters: _chapters, expectedProfile: _readerProfile);
  }

  Future<void> _toggleRead() async {
    if (!_sessionActive) return;
    final chapter = _activeChapter;
    if (widget.library.isChapterRead(widget.book, chapter, widget.sourceKey)) {
      _manuallyUnreadChapters.add(chapter.id);
      await _autoMarkChain;
      await widget.library.unmarkRead(widget.book, chapter, widget.sourceKey,
        availableChapters: _chapters, expectedProfile: _readerProfile);
    } else {
      _manuallyUnreadChapters.remove(chapter.id);
      await _mark();
    }
  }

  Future<void> _go(Chapter chapter) async {
    if (!_sessionActive) return;
    _stopAutoScroll();
    if (chapter.id == _activeChapter.id) return;
    _saveTimer?.cancel();
    await _flushPosition();
    if (!mounted || !_sessionActive) return;
    await Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ReaderPage(
      book: widget.book, chapter: chapter, sourceKey: widget.sourceKey,
      repository: widget.repository, library: widget.library, chapters: _chapters,
    )));
  }

  Future<void> _chapterList() async {
    if (_loadingChapters) return;
    _stopAutoScroll();
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
    // Match the chapter currently visible in the continuous reader, not
    // the first chapter with which ReaderPage was initially opened.
    final activeIndex = _chapters.indexWhere((ch) => ch.id == _activeChapter.id);
    final initialIndex = activeIndex >= 0 ? activeIndex : 0;
    final chapter = await showModalBottomSheet<Chapter>(context: context,
      useSafeArea: true, isScrollControlled: true,
      builder: (context) => SafeArea(child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(children: [
          const Padding(padding: EdgeInsets.all(16), child: Text('Главы')),
          Expanded(child: _chapters.isEmpty
            ? const Center(child: Text('Нет доступных глав'))
            : ScrollablePositionedList.builder(
              key: const Key('reader-chapter-picker'),
              itemCount: _chapters.length,
              initialScrollIndex: initialIndex,
              initialAlignment: 0.4,
              itemBuilder: (context, index) => ListTile(
                key: Key('reader-chapter-${_chapters[index].id}'),
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
    _stopAutoScroll();
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
    _stopAutoScroll();
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
    _stopAutoScroll();
    final itemIndex = _itemIndexForPage(_activeChapter, index);
    if (itemIndex != null && _itemScroll.isAttached) {
      _itemScroll.jumpTo(index: itemIndex);
    }
  }

  void _goToRoot(int destination) {
    _stopAutoScroll();
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

  void _stopAutoScroll({bool updateUi = true}) {
    // Invalidate any in-flight animation continuation on pause or dispose.
    _autoScrollRun++;
    if (!_autoScrolling) return;
    _autoScrolling = false;
    _scheduleGeometryCommit();
    if (mounted && updateUi) setState(() {});
  }

  Future<void> _runAutoScroll(int run) async {
    // Each animation moves a small, fixed number of physical pixels. Unlike
    // jumping by image index, this never skips the middle of tall webtoon pages.
    const frame = Duration(milliseconds: 160);
    while (mounted && _autoScrolling && run == _autoScrollRun) {
      if (!_itemScroll.isAttached || _segments.isEmpty) {
        _stopAutoScroll();
        break;
      }
      if (_autoAtBottom && _atSeriesEnd) {
        _stopAutoScroll();
        break;
      }
      if (_autoAtBottom && (_nextLoading || _nextScheduled)) {
        // Do not spin against the footer while the next chapter is loading.
        await Future<void>.delayed(frame);
        continue;
      }
      // The existing slider remains valid: N seconds per *viewport*, not per
      // source image. Thus a 5-screen-high image scrolls for ~5N seconds.
      final pixels = MediaQuery.sizeOf(context).height /
          _autoScrollSeconds * (frame.inMilliseconds / 1000);
      try {
        await _scrollOffset.animateScroll(
          offset: pixels, duration: frame, curve: Curves.linear);
      } catch (_) {
        if (mounted && run == _autoScrollRun) _stopAutoScroll();
        return;
      }
      if (_autoAtBottom && mounted && run == _autoScrollRun) {
        await Future<void>.delayed(frame);
      }
    }
  }

  void _toggleAutoscroll() {
    if (_autoScrolling) {
      _stopAutoScroll();
      return;
    }
    if (!_itemScroll.isAttached || _segments.isEmpty) return;
    setState(() => _autoScrolling = true);
    final run = ++_autoScrollRun;
    unawaited(_runAutoScroll(run));
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
                  _autoScrollSeconds.round().toString() + ' сек./экран')),
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
                IconButton(tooltip: !_autoScrolling
                    ? 'Автопрокрутка' : 'Остановить автопрокрутку',
                  onPressed: _pageCount > 0 ? _toggleAutoscroll : null,
                  icon: Icon(!_autoScrolling
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
    _frameMetrics?.readerBuilt();
    return Scaffold(
      backgroundColor: _lightTheme ? Colors.white : Colors.black,
      body: Stack(children: [
        Positioned.fill(child: LayoutBuilder(builder: (context, constraints) {
          _layoutWidth = constraints.maxWidth;
          return GestureDetector(
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
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Ошибка главы: ${snapshot.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white)),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _retryInitialChapter,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Повторить загрузку'),
                ),
              ])));
          }
          final pages = snapshot.data ?? [];
          if (pages.isEmpty) {
            return Center(child: Padding(padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Нет доступных изображений. Возможно, глава удалена или доступ ограничен.',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.white)),
                const SizedBox(height: 14),
                FilledButton.icon(onPressed: _retryInitialChapter,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Повторить загрузку')),
              ])));
          }
          final initialIndex = _resumePage.clamp(0, pages.length - 1).toInt();
          return NotificationListener<ScrollNotification>(
            onNotification: (notice) {
              if (notice is ScrollStartNotification) _scrollMoving = true;
              if (notice is ScrollEndNotification) {
                _scrollMoving = false;
                _scheduleGeometryCommit();
              }
              if (notice is ScrollUpdateNotification) {
                final now = _motionClock.elapsedMicroseconds;
                final delta = notice.scrollDelta ?? 0;
                if (delta != 0) _forward = delta > 0;
                if (now > _lastMotionUs && _lastMotionUs > 0) {
                  _velocity = .7 * _velocity + .3 * delta * 1000000 / (now - _lastMotionUs);
                }
                _lastMotionUs = now;
              }
              if (notice is ScrollStartNotification &&
                  notice.dragDetails != null && _autoScrolling) {
                // A user's swipe takes priority over automatic scrolling.
                _stopAutoScroll();
              }
              if (notice is ScrollUpdateNotification) {
                _autoAtBottom = notice.metrics.extentAfter <= 4;
              }
              if (notice is ScrollUpdateNotification &&
                  (notice.scrollDelta ?? 0) > 0) {
                _hasForwardScrolled = true;
                // At the absolute bottom, the last image still occupies part
                // of the viewport above the footer. Requiring it to disappear
                // would make last-chapter auto-read impossible.
                final firstReach = !_reachedScrollableEnd;
                _reachedScrollableEnd = notice.metrics.maxScrollExtent > 0 &&
                    notice.metrics.extentAfter <= 4;
                if (firstReach && _reachedScrollableEnd) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _autoCompletePassedChapters(
                      _positions.itemPositions.value);
                  });
                }
              }
              return false;
            },
            child: ScrollablePositionedList.builder(
            key: ValueKey('${widget.sourceKey}:${widget.chapter.id}'),
            itemPositionsListener: _positions,
            itemScrollController: _itemScroll,
            scrollOffsetController: _scrollOffset,
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
              final pageWidget = ValueListenableBuilder<double?>(
                valueListenable: _ratioFor(item.key),
                builder: (context, ratio, _) => _RetryableReaderImage(
                key: ValueKey('reader-image-${item.key}-${_chapterReloads[item.chapter.id] ?? 0}'),
                page: image,
                imageProvider: widget.imageProviderFactory?.call(image,
                  readerDecodeWidth(MediaQuery.sizeOf(context).width,
                    MediaQuery.devicePixelRatioOf(context))),
                pageIndex: item.index,
                width: constraints.maxWidth,
                height: _fitHeight ? MediaQuery.sizeOf(context).height : null,
                fit: _fitHeight ? BoxFit.contain : BoxFit.fitWidth,
                decodeWidth: readerDecodeWidth(
                  MediaQuery.sizeOf(context).width,
                  MediaQuery.devicePixelRatioOf(context)),
                knownHeight: _fitHeight || ratio == null ? null : ratio * constraints.maxWidth,
                onMeasuredHeight: (height) =>
                  _rememberHeight(item.key, height, width: constraints.maxWidth),
                onLoaded: () => _registerLoadedPage(item),
                onRefreshLinks: () => _refreshChapterImages(item.chapter),
              ));
              // No extra saveLayer/color processing at the default 100%
              // brightness: a long webtoon can contain dozens of images.
              if (_brightness >= 100) return pageWidget;
              return ColorFiltered(
                colorFilter: ColorFilter.mode(
                  Colors.black.withValues(alpha: (100 - _brightness) / 100),
                  BlendMode.srcATop),
                child: pageWidget,
              );
            },
          ));
        },
      ),
        ); })),
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

