import 'dart:async';
import 'package:flutter/material.dart';
import 'core/models.dart';
import 'core/chapter_identity.dart';
import 'data/catalog_repository.dart';
import 'data/senkuro_source.dart';
import 'data/senkuro_home_cache.dart';
import 'data/library_store.dart';
import 'data/reading_suggestions.dart';
import 'data/chapter_notification_service.dart';
import 'data/chapter_inbox_store.dart';
import 'ui/chapter_inbox_panel.dart';
import 'ui/notification_navigation.dart';
import 'data/chapter_background_scheduler.dart';
import 'ui/detail_page.dart';
import 'ui/reader_page.dart';
import 'ui/widgets.dart';
import 'data/chapter_alert_controller.dart';
import 'ui/chapter_alert_offer.dart';
import 'ui/settings_page.dart';
import 'data/theme_controller.dart';
import 'data/firebase_account_service.dart';
import 'ui/app_theme.dart';
import 'data/reader_activity.dart';

/// Reader route destinations, separate from saved library state.
final ValueNotifier<int> mainTabRequest = ValueNotifier<int>(0);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final library = LibraryStore();
  await library.load();
  final themes = ThemeController();
  try { await themes.load(); } catch (_) { /* Use the existing dark default. */ }
  final accounts = FirebaseAccountService(library);
  // Display the library immediately; native notifications/WorkManager setup
  // can take significant time and must not delay the first rendered frame.
  // The app listens for notification launch payloads as soon as it mounts.
  runApp(SenReaderApp(library: library, themes: themes, accounts: accounts));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_initializeBackgroundServices());
    unawaited(accounts.initialize().catchError((Object _) {}));
    // Local catch-up uses the persisted active profile and must not wait for
    // Firebase or a native notification/WorkManager initialization to finish.
    unawaited(ChapterBackgroundScheduler.checkOnResume());
  });
}

/// Keep OS integrations out of the cold-start critical path. Initialize
/// independently so one unavailable plugin cannot disable the other.
Future<void> _initializeBackgroundServices() async {
  await Future.wait([
    ChapterNotificationService.instance.initialize().catchError((Object _) {}),
    ChapterBackgroundScheduler.initialize().catchError((Object _) {}),
  ]);
}

class SenReaderApp extends StatelessWidget {
  const SenReaderApp({super.key, required this.library, required this.themes,
    this.accounts});
  final LibraryStore library;
  final ThemeController themes;
  final FirebaseAccountService? accounts;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: themes,
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SenReader',
      theme: SenReaderTheme.build(Brightness.light),
      darkTheme: SenReaderTheme.build(Brightness.dark),
      themeMode: themes.mode,
      home: MainShell(repository: CatalogRepository(),
          library: library, themes: themes, accounts: accounts),
    ),
  );
}

class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.repository, required this.library,
    this.alerts, this.themes, this.accounts});
  final ChapterAlertController? alerts;
  final ThemeController? themes;
  final FirebaseAccountService? accounts;
  final CatalogRepository repository;
  final LibraryStore library;
  @override State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int tab = 0;

  void _onMainTabRequest() {
    final next = mainTabRequest.value;
    if (!mounted || tab == next) return;
    _changeTab(next);
  }

  /// Leave Catalog with a clean sort/filter/search session.
  void _changeTab(int next) {
    if (!mounted || tab == next) return;
    debounce?.cancel();
    setState(() {
      if (tab == 1) {
        query = '';
        searchController.clear();
        catalogType = null;
        catalogStatus = null;
        catalogTranslationStatus = null;
        catalogLabelSlug = null;
        catalogLabelTitle = null;
        catalogTagFilter = null;
        catalogSort = 'popularity';
        result = null;
        _catalogHasMore = false;
        _catalogLoadingMore = false;
        ++_catalogGeneration;
        loading = false;
      }
      tab = next;
    });
    if (next == 0) unawaited(_refreshNewChapters());
    if (next == 1) unawaited(_fetch());
    if (next == 3) unawaited(_refreshInboxCount());
    if (next == 2 && widget.library.items.isNotEmpty) {
      unawaited(offerChapterAlerts(context, alerts));
      unawaited(_refreshLibraryRatings());
    }
  }

  int _newUpdateCount = 0;
  Timer? _inboxRefreshTimer;
  bool _isInForeground = true;
  bool _inboxPollInFlight = false;

  /// The WorkManager isolate writes SQLite without notifying Flutter widgets.
  /// Re-read local results while the user watches Home or New Chapters.
  /// This performs no network requests and does not start a new scan.
  Future<void> _pollChapterInbox() async {
    // Home stays mounted under the reader route. Its 20 s SQLite reload and
    // full-screen setState measured as 15-42 ms main-thread frames while
    // reading; nothing of it is visible then. Catch up when the reader closes.
    if (!mounted || !_isInForeground || _inboxPollInFlight ||
        ReaderActivity.isOpen || (tab != 0 && tab != 3)) return;
    _inboxPollInFlight = true;
    try {
      await _refreshInboxCount();
    } catch (_) {
      // A transient database error must not interrupt normal reading.
    } finally {
      _inboxPollInFlight = false;
    }
  }

  Future<void> _refreshInboxCount() async {
    final profile = widget.library.profileId;
    final entries = await ChapterInboxStore(profileId: profile).load();
    if (!mounted || widget.library.profileId != profile) return;
    final count = entries.where((e) => !e.hidden && !e.read && !e.deleted).map((e) => e.bookKey).toSet().length;
    if (count != _newUpdateCount) {
      setState(() => _newUpdateCount = count);
    }
    // On Home, reload the local latest chapter identities too: even if an
    // entry was replaced or archived, the unread count may be unchanged.
    if (tab == 0) await _refreshNewChapters();
  }

  String libraryFilter = 'all';
  String? catalogType;
  String? catalogStatus;
  String? catalogTranslationStatus;
  String? catalogLabelSlug;
  String? catalogLabelTitle;
  String? catalogTagFilter;
  String catalogSort = 'popularity';
  CatalogResult? result;
  CatalogResult? _homeResult; // Never replaced by catalog search results.
  bool loading = false;
  int _suggestionRequest = 0;
  DateTime? _lastSuggestionsRefreshAt;
  final Map<String, Chapter> _newChapters = {};
  int _homeRequest = 0;
  final Map<String, List<MangaEntry>> _senkuroSections = {};
  final SenkuroHomeCache _homeCache = SenkuroHomeCache();
  DateTime? _lastLibraryRatingsAttempt;
  bool _libraryRatingsLoading = false;

  /// Repair old saved entries that did not store a Senkuro score. Use the
  /// lightweight score-only GraphQL query in batches, never fetch chapters.
  /// Results arrive gradually without blocking the bookmark grid.
  Future<void> _refreshLibraryRatings() async {
    final source = widget.repository.sources['senkuro'];
    if (source is! SenkuroSource || _libraryRatingsLoading) return;
    final now = DateTime.now();
    if (_lastLibraryRatingsAttempt != null &&
        now.difference(_lastLibraryRatingsAttempt!) <
            const Duration(minutes: 30)) return;
    final unrated = widget.library.items
        .where((saved) => saved.status != 'viewed' || saved.favorite)
        .map((saved) => saved.entries['senkuro'])
        .whereType<MangaEntry>()
        .where((entry) => entry.id.isNotEmpty && entry.rating == null)
        .toList();
    if (unrated.isEmpty) return;
    _lastLibraryRatingsAttempt = now;
    _libraryRatingsLoading = true;
    try {
      // Seven small requests for a library of 70 titles; run sequentially
      // and stop when user leaves the tab to avoid background network bursts.
      for (var i = 0; i < unrated.length; i += 10) {
        if (!mounted || tab != 2) break;
        final batch = unrated.skip(i).take(10).toList();
        final verified = await source.verifiedRatings(batch);
        if (!mounted) break;
        await widget.library.updateVerifiedRatings(verified);
      }
    } catch (_) {
      // Missing or temporarily unavailable score is not a zero rating.
    } finally {
      _libraryRatingsLoading = false;
    }
  }
  late final ChapterAlertController alerts = widget.alerts ?? ChapterAlertController();
  String query = '';
  Timer? debounce;
  final TextEditingController searchController = TextEditingController();

  @override void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    tab = mainTabRequest.value;
    mainTabRequest.addListener(_onMainTabRequest);
    _fetch();
    if (tab == 2) unawaited(_refreshLibraryRatings());
    unawaited(_refreshInboxCount());
    _inboxRefreshTimer = Timer.periodic(const Duration(seconds: 20),
        (_) => unawaited(_pollChapterInbox()));
    ReaderActivity.open.addListener(_onReaderActivity);
    ChapterNotificationService.instance.openedPayload.addListener(_onNotificationTap);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onNotificationTap());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isInForeground = state == AppLifecycleState.resumed;
    if (_isInForeground) {
      unawaited(ChapterBackgroundScheduler.checkOnResume());
      unawaited(_pollChapterInbox());
    }
  }

  void _onReaderActivity() {
    if (!ReaderActivity.isOpen) unawaited(_pollChapterInbox());
  }

  @override void dispose() {
    ReaderActivity.open.removeListener(_onReaderActivity);
    WidgetsBinding.instance.removeObserver(this);
    debounce?.cancel();
    _inboxRefreshTimer?.cancel();
    mainTabRequest.removeListener(_onMainTabRequest);
    ChapterNotificationService.instance.openedPayload.removeListener(_onNotificationTap);
    searchController.dispose();
    super.dispose();
  }

  bool _catalogLoadingMore = false;
  bool _catalogHasMore = false;
  int _catalogNextOffset = 30;
  int _catalogGeneration = 0;

  Future<void> _loadMoreCatalog() async {
    if (_catalogLoadingMore || !_catalogHasMore || loading || tab != 1) return;
    final source = widget.repository.sources['senkuro'];
    if (source is! SenkuroSource) return;
    final current = result?.books ?? const <UnifiedManga>[];
    // Server offset is the number of remote rows consumed, not the number
    // of unique visible cards: duplicates must not break paging.
    final offset = _catalogNextOffset;
    if (offset > 970 || offset % 10 != 0) return;
    final version = _catalogGeneration;
    setState(() => _catalogLoadingMore = true);
    try {
      final matches = await source.filteredCatalog(query: query,
        type: catalogType, status: catalogStatus,
        translationStatus: catalogTranslationStatus, label: catalogLabelSlug,
        offset: offset, orderField: catalogSort == 'rating'
          ? 'SCORE' : 'POPULARITY_SCORE', withRatings: true);
      if (!mounted || version != _catalogGeneration || tab != 1) return;
      final seen = current.map((item) => item.primary.id).toSet();
      final fresh = matches.where((item) => seen.add(item.id)).toList();
      setState(() {
        result = CatalogResult(books: [
          ...current,
          for (final item in fresh)
            UnifiedManga(title: item.title, entries: {'senkuro': item}),
        ], warnings: result?.warnings ?? const []);
        _catalogNextOffset = offset + matches.length;
        _catalogHasMore = matches.length == 30 && fresh.isNotEmpty &&
            offset + matches.length <= 970;
      });
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Не удалось загрузить следующую страницу каталога')));
    } finally {
      if (mounted) setState(() => _catalogLoadingMore = false);
    }
  }

  Future<void> _fetch({bool forceHome = false}) async {
    final thisQuery = query;
    final isCatalog = tab == 1;
    final type = catalogType;
    final status = catalogStatus;
    final translation = catalogTranslationStatus;
    final label = catalogLabelSlug;
    final sort = catalogSort;
    final catalogGeneration = ++_catalogGeneration;
    setState(() { loading = true; _catalogLoadingMore = false; });
    CatalogResult next;
    final senkuro = widget.repository.sources['senkuro'];
    if (isCatalog && thisQuery.trim().isNotEmpty) {
      // Search all providers, while the browsing catalog stays Senkuro-only.
      next = await widget.repository.getCatalog(query: thisQuery);
    } else if (isCatalog && senkuro is SenkuroSource &&
        (sort == 'rating' || status != null || translation != null || label != null ||
            (type != null && (thisQuery.isNotEmpty ||
              !const {'MANGA', 'MANHWA', 'MANHUA'}.contains(type))))) {
      try {
        final entries = await senkuro.filteredCatalog(query: thisQuery,
          type: type, status: status, translationStatus: translation,
          label: label, orderField: sort == 'rating' ? 'SCORE' : 'POPULARITY_SCORE',
          withRatings: true);
        next = CatalogResult(
          books: [for (final entry in entries)
            UnifiedManga(title: entry.title, entries: {'senkuro': entry})],
          warnings: const []);
      } catch (e) {
        next = CatalogResult(books: const [], warnings: ['Senkuro: $e']);
      }
    } else if (isCatalog && thisQuery.isEmpty && senkuro is SenkuroSource &&
        (type != null || sort == 'updated' || sort == 'created')) {
      try {
        final entries = await senkuro.browseHome(type: type, first: 30,
          orderField: sort == 'updated' ? 'LAST_CHAPTER_AT'
            : sort == 'created' ? 'CREATED_AT' : 'POPULARITY_SCORE');
        next = CatalogResult(
          books: [for (final entry in entries)
            UnifiedManga(title: entry.title, entries: {'senkuro': entry})],
          warnings: const []);
      } catch (e) {
        next = CatalogResult(books: const [], warnings: ['Senkuro: $e']);
      }

    } else if (!isCatalog && thisQuery.isEmpty && senkuro is SenkuroSource) {
      try {
        var entries = forceHome ? null : await _homeCache.load('popular');
        if (entries == null) {
          entries = await senkuro.popular();
          unawaited(_homeCache.save('popular', entries));
        }
        next = CatalogResult(
          books: [for (final entry in entries)
            UnifiedManga(title: entry.title, entries: {'senkuro': entry})],
          senkuroPopular: entries,
          warnings: const []);
      } catch (e) {
        next = CatalogResult(books: const [], warnings: ['Senkuro: $e']);
      }
    } else {
      next = await widget.repository.getCatalog(query: thisQuery,
        sourceKey: isCatalog ? 'senkuro' : null);
    }
    if (!mounted || catalogGeneration != _catalogGeneration ||
        thisQuery != query || isCatalog != (tab == 1) ||
        (isCatalog && (type != catalogType || status != catalogStatus ||
            translation != catalogTranslationStatus ||
            label != catalogLabelSlug || sort != catalogSort))) return;
    setState(() {
      result = next;
      if (!isCatalog && thisQuery.isEmpty) _homeResult = next;
      loading = false;
      _catalogNextOffset = 30;
      _catalogHasMore = isCatalog && senkuro is SenkuroSource &&
          next.books.length == 30 && (sort == 'rating' || status != null ||
          translation != null || label != null);
    });
    // Scanning every saved title on each catalogue search made Senkuro
    // sluggish. Do it only on Home, at most once per 15 minutes.
    if (!isCatalog && thisQuery.isEmpty) {
      // Prioritize visible home sections. Background library scans start only
      // after the browse feed settles, avoiding a burst of Senkuro requests.
      unawaited(_refreshSenkuroSections(force: forceHome).whenComplete(() {
        if (mounted && tab == 0) {
          unawaited(_refreshNewChapters(force: forceHome));
        }
      }));
    }
  }

  Future<void> _refreshSenkuroSections({bool force = false}) async {
    final source = widget.repository.sources['senkuro'];
    if (source is! SenkuroSource) return;
    final request = ++_homeRequest;
    final categories = <String, List<MangaEntry>>{};
    final options = <(String, String?, String)>[
      ('Последние обновления', null, 'LAST_CHAPTER_AT'),
      ('Топ манхв', 'MANHWA', 'POPULARITY_SCORE'),
      ('Топ маньхуа', 'MANHUA', 'POPULARITY_SCORE'),
      ('Топ манг', 'MANGA', 'POPULARITY_SCORE'),
    ];
    // Fetch at most two categories concurrently instead of four requests
    // plus the saved-title scan racing the user's foreground navigation.
    for (var offset = 0; offset < options.length; offset += 2) {
      await Future.wait(options.skip(offset).take(2).map((option) async {
        try {
          var list = force ? null : await _homeCache.load(option.$1);
          if (list == null) {
            list = await source.browseHome(
              type: option.$2, orderField: option.$3);
            if (list.isNotEmpty) unawaited(_homeCache.save(option.$1, list));
          }
          if (list.isNotEmpty) categories[option.$1] = list;
        } catch (_) {
          // Category-specific failures never hide the regular catalog.
        }
      }));
      if (!mounted || request != _homeRequest) return;
      // Show the first categories while the next pair loads.
      setState(() => _senkuroSections..clear()..addAll(categories));
    }
  }

  Future<void> _refreshNewChapters({bool force = false}) async {
    final request = ++_suggestionRequest;
    final saved = widget.library.items
      .where((item) => item.lastChapter.isNotEmpty &&
        item.lastSource == item.preferredSource &&
        item.status == 'reading').toList()
      ..sort((a, b) => b.lastUpdatedAt.compareTo(a.lastUpdatedAt));
    // Home renders durable inbox results; network discovery uses the fair queue.
    final profile = widget.library.profileId;
    final inbox = await ChapterInboxStore(profileId: profile).load();
    if (!mounted || request != _suggestionRequest ||
        profile != widget.library.profileId) return;
    final suggestions = unreadInboxSuggestions(saved, inbox);
    setState(() { _newChapters..clear()..addAll(suggestions); });


  }

  void _onSearch(String value) {
    query = value;
    if (value.trim().isNotEmpty) {
      // Search must not silently exclude ReadManga and ReManga.
      setState(() {
        catalogSort = 'popularity';
        catalogType = null;
        catalogStatus = null;
        catalogTranslationStatus = null;
        catalogTagFilter = null;
        catalogLabelSlug = null;
        catalogLabelTitle = null;
      });
    }
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 450), _fetch);
  }

  /// Local controls apply to the results returned by the available sources;
  /// they are not a claim of server-wide filtered or chronological ranking.
  List<UnifiedManga> _visibleCatalogBooks() {
    final books = (result?.books ?? const <UnifiedManga>[])
        .where((book) => (query.trim().isNotEmpty ||
            book.entries.containsKey('senkuro')) &&
          (catalogTagFilter == null ||
            book.entries['senkuro']?.tags.contains(catalogTagFilter) == true))
        .toList();
    if (catalogSort == 'rating' && widget.repository.sources['senkuro'] is! SenkuroSource) {
      // Preserve source order for unknown scores; never invent zero ratings.
      books.sort((a, b) {
        final left = a.primary.rating;
        final right = b.primary.rating;
        if (left == null) return right == null ? 0 : 1;
        if (right == null) return -1;
        return right.compareTo(left);
      });
    }
    return books;
  }

  List<String> get _catalogTags {
    final counts = <String, int>{};
    for (final book in result?.books ?? const <UnifiedManga>[]) {
      for (final tag in book.entries.values.expand((e) => e.tags).toSet()) {
        counts.update(tag, (value) => value + 1, ifAbsent: () => 1);
      }
    }
    final tags = counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount == 0 ? a.compareTo(b) : byCount;
      });
    return tags;
  }

  void _openCatalogTags() {
    var search = '';
    final source = widget.repository.sources['senkuro'];
    final labelsFuture = source is SenkuroSource
        ? source.catalogLabels().catchError((Object _) => <SenkuroCatalogLabel>[])
        : null;
    showModalBottomSheet<void>(context: context, useSafeArea: true,
      isScrollControlled: true, builder: (sheetContext) =>
        StatefulBuilder(builder: (sheetContext, setSheet) {
          final tags = _catalogTags.where((tag) =>
            tag.toLowerCase().contains(search.toLowerCase())).toList();
          void select(void Function() update) {
            setState(() {
              update();
              if ((catalogStatus != null || catalogTranslationStatus != null ||
                   catalogLabelSlug != null) &&
                  (catalogSort != 'popularity')) {
                catalogSort = 'popularity';
              }
            });
            setSheet(() {});
            unawaited(_fetch());
          }
          return SizedBox(height: MediaQuery.sizeOf(context).height * 0.8,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Row(children: [
                const Expanded(child: Text('Фильтры Senkuro',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
                TextButton(onPressed: () => select(() {
                  catalogType = null; catalogStatus = null;
                  catalogTranslationStatus = null; catalogTagFilter = null;
                  catalogLabelSlug = null; catalogLabelTitle = null;
                }), child: const Text('Сбросить')),
              ]),
              const SizedBox(height: 12),
              const Text('Тип произведения'),
              Wrap(spacing: 6, children: [
                for (final option in const [
                  (null, 'Все'), ('MANGA', 'Манга'), ('MANHWA', 'Манхва'),
                  ('MANHUA', 'Маньхуа'), ('COMICS', 'Комикс'),
                ])
                  ChoiceChip(label: Text(option.$2),
                    selected: catalogType == option.$1,
                    onSelected: (_) => select(() => catalogType = option.$1)),
              ]),
              const SizedBox(height: 12),
              const Text('Статус выпуска'),
              Wrap(spacing: 6, children: [
                for (final option in const [
                  (null, 'Любой'), ('ONGOING', 'Онгоинг'),
                  ('FINISHED', 'Выпущено'), ('HIATUS', 'Приостановлено'),
                  ('CANCELLED', 'Отменено'), ('ANNOUNCE', 'Анонс'),
                ])
                  ChoiceChip(label: Text(option.$2),
                    selected: catalogStatus == option.$1,
                    onSelected: (_) => select(() => catalogStatus = option.$1)),
              ]),
              const SizedBox(height: 12),
              const Text('Статус перевода'),
              Wrap(spacing: 6, children: [
                for (final option in const [
                  (null, 'Любой'), ('IN_PROGRESS', 'Переводится'),
                  ('FINISHED', 'Переведено'), ('FROZEN', 'Заморожено'),
                  ('ABANDONED', 'Заброшено'),
                ])
                  ChoiceChip(label: Text(option.$2),
                    selected: catalogTranslationStatus == option.$1,
                    onSelected: (_) => select(() =>
                      catalogTranslationStatus = option.$1)),
              ]),
              const SizedBox(height: 12),
              const Text('Жанры Senkuro'),
              TextField(onChanged: (v) => setSheet(() => search = v),
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search),
                  hintText: 'Поиск жанра, темы или тега')),
              if (labelsFuture != null)
                FutureBuilder<List<SenkuroCatalogLabel>>(future: labelsFuture,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Padding(padding: EdgeInsets.all(12),
                        child: Center(child: CircularProgressIndicator()));
                    }
                    final found = snapshot.data!.where((entry) =>
                      search.isNotEmpty && entry.title.toLowerCase()
                        .contains(search.toLowerCase())).take(35).toList();
                    return Wrap(spacing: 5, children: [
                      if (catalogLabelSlug != null)
                        InputChip(label: Text(catalogLabelTitle ?? catalogLabelSlug!),
                          onDeleted: () => select(() {
                            catalogLabelSlug = null; catalogLabelTitle = null;
                          })),
                      for (final entry in found)
                        FilterChip(label: Text(entry.title),
                          selected: catalogLabelSlug == entry.slug,
                          onSelected: (yes) => select(() {
                            catalogLabelSlug = yes ? entry.slug : null;
                            catalogLabelTitle = yes ? entry.title : null;
                            catalogTagFilter = null;
                          })),
                    ]);
                  }),
              const SizedBox(height: 12),
              const Text('Метки загруженных произведений (локально)'),
              TextField(onChanged: (v) => setSheet(() => search = v),
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search),
                  hintText: 'Поиск жанра или тега')),
              const SizedBox(height: 12),
              if (tags.isNotEmpty)
                Wrap(spacing: 5, children: [
                  for (final tag in tags)
                    FilterChip(label: Text(tag),
                      selected: catalogTagFilter == tag,
                      onSelected: (yes) => select(() =>
                        catalogTagFilter = yes ? tag : null)),
                ]),
              const SizedBox(height: 14),
              FilledButton(onPressed: () => Navigator.pop(sheetContext),
                child: const Text('Показать результаты')),
            ]));
        }),
    );
  }

  Widget _sourceRow(String title, Iterable<UnifiedManga> books) {
    final items = books.take(12).toList();
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(top: 25, bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SectionTitle(title),
        const SizedBox(height: 12),
        SingleChildScrollView(scrollDirection: Axis.horizontal,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final book in items) ...[
                SizedBox(width: 116, child: MangaTile(
                  book: book, saved: widget.library.get(book),
                  onTap: () => _open(book))),
                const SizedBox(width: 10),
              ],
            ])),
      ]));
  }

  Widget _homeCollections() {
    return Column(children: [
      for (final section in const [
        'Последние обновления', 'Топ манхв',
        'Топ маньхуа', 'Топ манг',
      ])
        if (_senkuroSections[section]?.isNotEmpty == true)
          _sourceRow(section,
            _senkuroSections[section]!.map((entry) =>
              UnifiedManga(title: entry.title, entries: {'senkuro': entry}))),
    ]);
  }

  Widget _catalogControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(spacing: 8, runSpacing: 6, children: [
        PopupMenuButton<String>(
          key: const Key('catalog-sort'),
          tooltip: 'Сортировка каталога Senkuro',
          initialValue: catalogSort,
          onSelected: (value) { setState(() => catalogSort = value); _fetch(); },
          itemBuilder: (context) => [
            PopupMenuItem(value: 'popularity', child: Text('По популярности')),
            const PopupMenuItem(value: 'rating', child: Text('По рейтингу')),
            PopupMenuItem(value: 'updated',
              enabled: catalogStatus == null && catalogTranslationStatus == null &&
                  catalogLabelSlug == null && query.isEmpty,
              child: const Text('По дате обновления')),
            PopupMenuItem(value: 'created',
              enabled: catalogStatus == null && catalogTranslationStatus == null &&
                  catalogLabelSlug == null && query.isEmpty,
              child: const Text('По дате создания')),
            // Senkuro exposes SCORE, POPULARITY_SCORE and date-based browse.
            // There are no verified global sort fields for views/chapter count.
          ],
          child: Chip(avatar: const Icon(Icons.swap_vert, size: 18),
            label: Text(catalogSort == 'rating' ? 'По рейтингу' :
              catalogSort == 'updated' ? 'По обновлению' :
              catalogSort == 'created' ? 'По созданию' : 'По популярности')),
        ),
        ActionChip(
          key: const Key('catalog-tag-filters'),
          avatar: const Icon(Icons.tune, size: 18),
          label: Text(catalogTagFilter == null && catalogType == null &&
              catalogStatus == null && catalogTranslationStatus == null &&
              catalogLabelSlug == null ?
            'Фильтры' : catalogTagFilter != null ?
              'Тег: $catalogTagFilter' : 'Фильтры активны'),
          onPressed: _openCatalogTags,
        ),

      ]),
      Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 12),
        child: Text(catalogSort == 'rating'
          ? 'Senkuro · сортировка по рейтингу'
          : catalogSort == 'popularity'
            ? 'Senkuro · сортировка по популярности'
            : 'Senkuro · сортировка по дате',
          style: TextStyle(fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ),
    ],
  );

  void _open(UnifiedManga book) {
    // Viewing is a separate category, not the "В планах" library status.
    Navigator.push(context, MaterialPageRoute(builder: (_) => DetailPage(
      book: book, repository: widget.repository, library: widget.library, alerts: alerts,
    ))).then((_) {
      if (mounted) {
        setState(() {}); // Update visible cover badges after status changes.
        unawaited(_refreshNewChapters());
      }
    });
  }

  Future<void> _resume(SavedBook saved, Chapter? newChapter) async {
    await widget.library.load();
    final current = recentReadingBooks(widget.library.items)
      .where((book) => book.key == saved.key).firstOrNull;
    if (current == null || !mounted) return;
    saved = current;
    final book = saved.toUnified();
    final entry = saved.entries[saved.lastSource];
    final source = widget.repository.sources[saved.lastSource];
    if (saved.lastSource != saved.preferredSource || entry == null || source == null || saved.lastChapter.isEmpty) {
      _open(book);
      return;
    }
    try {
      final detail = await source.detail(entry);
      // Resume persisted progress first; do not advance just because a new chapter exists.
      final target = detail.chapters.where((chapter) => saved.lastChapterId.isNotEmpty
        ? chapter.id == saved.lastChapterId : chapter.name == saved.lastChapter).firstOrNull;
      if (!mounted) return;
      if (target == null) {
        _open(book);
      } else {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => ReaderPage(
          book: book, chapter: target!, sourceKey: saved.lastSource,
          repository: widget.repository, library: widget.library, chapters: detail.chapters,
        )));
        if (mounted) unawaited(_refreshNewChapters());
      }
    } catch (_) {
      if (!mounted) return;
      _open(book);
    }
  }

  Widget _continueReading() => AnimatedBuilder(
    animation: widget.library,
    builder: (context, _) {
      final saved = recentReadingBooks(widget.library.items);
      if (saved.isEmpty) return const SizedBox.shrink();
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 28),
        SectionTitle('Читаемое сейчас',
          subtitle: 'Вернуться к сохранённой странице'),
        SizedBox(height: 186, child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: saved.take(12).length,
          separatorBuilder: (context, index) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final item = saved[index];
            return SizedBox(width: 258, child: InkWell(
              onTap: () => _resume(item, _newChapters[item.key]),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(14)),
                child: Row(children: [
                  ClipRRect(borderRadius: BorderRadius.circular(9),
                    child: CoverImage(item.toUnified().coverUrl,
                      width: 82, height: 124)),
                  const SizedBox(width: 9),
                  // Scale down only when accessibility text would overflow,
                  // while retaining two lines and readable saved progress.
                  Expanded(child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: SizedBox(width: 145, child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.title, maxLines: 2,
                        overflow: TextOverflow.ellipsis, softWrap: true,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 7),
                      Text('Сохранено: ${displayChapterName(item.lastChapter)}',
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11)),
                      if (item.lastPageCount > 0) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: (item.lastPageIndex + 1) / item.lastPageCount,
                          backgroundColor: Theme.of(context).colorScheme.outlineVariant),
                        const SizedBox(height: 4),
                        Text('Стр. ${item.lastPageIndex + 1}/${item.lastPageCount}',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                         if (item.lastUpdatedAt > 0) ...[
                           const SizedBox(height: 3),
                           Text('Читал: ' +
                             DateTime.fromMillisecondsSinceEpoch(item.lastUpdatedAt).day.toString().padLeft(2, '0') +
                             '.' + DateTime.fromMillisecondsSinceEpoch(item.lastUpdatedAt).month.toString().padLeft(2, '0'),
                             style: TextStyle(fontSize: 10,
                               color: Theme.of(context).colorScheme.onSurfaceVariant)),
                         ],
                      ],
                    ],
                  )))),
                ]),
              ),
            ));
          },
        )),
      ]);
    },
  );

  Future<void> _onNotificationTap() async {
    final state = ChapterNotificationService.instance.openedPayload;
    final payload = state.value;
    if (payload == null || !mounted) return;
    state.value = null; // Never re-open on UI rebuild.
    final info = ChapterNotificationService.decodePayload(payload);
    if (info == null) return;
    await openChapterNotification(context, fields: info, library: widget.library,
      repository: widget.repository, alerts: alerts);
  }

  @override Widget build(BuildContext context) {
    // A search must never replace the home feed when switching tabs.
    final activeResult = tab == 0 ? _homeResult : result;
    final catalogBooks = tab == 1 ? _visibleCatalogBooks() :
        _homeResult?.books ?? <UnifiedManga>[];
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Icon(Icons.auto_stories_rounded, size: 25, color: Color(0xFFFF893F)),
          const SizedBox(width: 10),
          Expanded(child: Text(tab == 0 ? 'SenReader' : tab == 1 ? 'Каталог' : tab == 2 ? 'Мои закладки' : tab == 3 ? 'Уведомления' : 'Ещё',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800))),
        ]),
        actions: [
          if (tab == 0 || tab == 1)
            IconButton(tooltip: 'Обновить', icon: const Icon(Icons.refresh),
              onPressed: () => _fetch(forceHome: true)),
          IconButton(tooltip: 'Настройки', icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage(
              repository: widget.repository, library: widget.library, alerts: alerts,
               themes: widget.themes, accounts: widget.accounts)))),
        ],
      ),
      body: tab == 3 ? ChapterInboxPanel(
        library: widget.library, repository: widget.repository, alerts: alerts,
        onChanged: _refreshInboxCount,
      ) : tab == 4 ? ListView(padding: const EdgeInsets.all(16), children: [
        const SectionTitle('Ещё'),
        ListTile(leading: const Icon(Icons.settings_outlined),
          title: const Text('Настройки'),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) =>
            SettingsPage(repository: widget.repository, library: widget.library,
              alerts: alerts, themes: widget.themes,
              accounts: widget.accounts)))),
        ListTile(leading: const Icon(Icons.notifications_active_outlined),
          title: const Text('Уведомления о главах'),
          onTap: () => setState(() => tab = 3)),
      ]) : tab == 2 ? AnimatedBuilder(
        animation: widget.library,
        builder: (context, _) {
          final saved = widget.library.items.where(
            (item) => item.status != 'viewed' || item.favorite).toList();
          final filtered = saved.where((item) =>
            libraryFilter == 'all' || (libraryFilter == 'favorite'
              ? item.favorite : item.status == libraryFilter)).toList();
          return saved.isEmpty
            ? const EmptyView(icon: Icons.bookmark_border, text: 'Здесь появятся сохранённые тайтлы')
            : ListView(padding: const EdgeInsets.all(16), children: [
                SectionTitle('Мои закладки', subtitle: '${saved.length} произведений'),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final option in const [
                      ('all', 'Все'),
                      ('reading', 'Читаю'), ('planned', 'В планах'),
                      ('completed', 'Прочитано'), ('dropped', 'Заброшено'),
                      ('favorite', 'Любимое')
                    ]) ...[
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text('${option.$2} ${option.$1 == 'all' ? saved.length : saved.where((b) => option.$1 == 'favorite' ? b.favorite : b.status == option.$1).length}'),
                          selected: libraryFilter == option.$1,
                          onSelected: (_) => setState(() => libraryFilter = option.$1),
                        ),
                      ),
                    ],
                  ]),
                ),
                const SizedBox(height: 16),
                if (filtered.isEmpty)
                  const EmptyView(icon: Icons.bookmark_border,
                    text: 'В этой категории пока нет произведений'),
                LayoutBuilder(builder: (context, constraints) => Wrap(
                  spacing: 10, runSpacing: 18,
                  children: filtered.map((item) => SizedBox(
                    width: (constraints.maxWidth - 20) / 3,
                    child: MangaTile(
                      book: item.toUnified(),
                      saved: item,
                      onTap: () => _open(item.toUnified())),
                  )).toList(),
                )),
              ]);
        },
      ) : Column(children: [
        if (tab == 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: TextField(
              key: const Key('catalog-search'),
              controller: searchController,
              onChanged: _onSearch,
              decoration: InputDecoration(
                hintText: 'Поиск: Senkuro, ReadManga',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide: BorderSide.none),
              ),
            ),
          ),
        Expanded(child: RefreshIndicator(
        onRefresh: () => _fetch(forceHome: true),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
          children: [
            if (tab == 0) ...[
              TextField(
                readOnly: true,
                onTap: () => _changeTab(1),
                decoration: InputDecoration(
                  hintText: 'Поиск манги, манхвы или маньхуа',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(15),
                    borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 22),
              const SectionTitle('Самое популярное',
                subtitle: 'Senkuro · сортировка по популярности'),
              if (loading)
                const SizedBox(height: 195,
                  child: Center(child: CircularProgressIndicator())),
              if ((tab == 0 || !loading) && activeResult != null &&
                  activeResult!.senkuroPopular.isNotEmpty)
                // Size the horizontal carousel by its actual tile content,
                // including OS font scaling, rather than a fragile fixed height.
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                    for (final item in activeResult!.senkuroPopular.take(15)) ...[
                      SizedBox(width: 116, child: MangaTile(
                        book: UnifiedManga(title: item.title,
                          entries: {'senkuro': item}),
                        saved: widget.library.get(UnifiedManga(
                          title: item.title, entries: {'senkuro': item})),
                        onTap: () => _open(UnifiedManga(title: item.title,
                          entries: {'senkuro': item})),
                      )),
                      const SizedBox(width: 10),
                    ],
                  ]),
                ),
              _continueReading(),
              if (_homeResult != null) _homeCollections(),
              const SizedBox(height: 30),
            ] else ...[
              if (query.isEmpty) _catalogControls(),
            ],
            if (tab == 1) ...[
            SectionTitle(query.isEmpty ? 'Каталог' : 'Результаты поиска',
              subtitle: query.isEmpty
                  ? 'Senkuro' : 'Senkuro · ReadManga'),
            if (loading)
              const Padding(padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator())),
            if (activeResult != null && activeResult.warnings.isNotEmpty)
              ...activeResult!.warnings.map((w) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(w, style: const TextStyle(color: Color(0xFFFFBE80), fontSize: 12)),
              )),
            if (!loading && activeResult != null && catalogBooks.isEmpty)
              const EmptyView(icon: Icons.search_off,
                text: 'По заданным фильтрам ничего не найдено.'),
            if (!loading && activeResult != null && catalogBooks.isNotEmpty)
              LayoutBuilder(builder: (context, box) => Wrap(
                spacing: 10, runSpacing: 18,
                children: catalogBooks.map((book) => SizedBox(
                  width: (box.maxWidth - 20) / 3,
                  child: MangaTile(book: book,
                    saved: widget.library.get(book), onTap: () => _open(book)),
                )).toList(),
              )),
            if (_catalogHasMore)
              Padding(padding: const EdgeInsets.all(12), child: Center(
                child: FilledButton.icon(
                  onPressed: _catalogLoadingMore ? null : _loadMoreCatalog,
                  icon: _catalogLoadingMore ? const SizedBox(width: 16,
                    height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.expand_more),
                  label: Text(_catalogLoadingMore ? 'Загрузка…' : 'Загрузить ещё'),
                ))),
            ],
          ],
        ),
      ))]),
      bottomNavigationBar: NavigationBarTheme(
        data: const NavigationBarThemeData(
          labelTextStyle: WidgetStatePropertyAll(TextStyle(
            fontSize: 10.5, fontWeight: FontWeight.w600))),
        child: NavigationBar(
        height: 72,
        selectedIndex: tab,
        onDestinationSelected: _changeTab,
        destinations: [
          const NavigationDestination(icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home), label: 'Главная'),
          const NavigationDestination(icon: Icon(Icons.layers_outlined),
            selectedIcon: Icon(Icons.layers), label: 'Каталог'),
          const NavigationDestination(icon: Icon(Icons.bookmark_border),
            selectedIcon: Icon(Icons.bookmark), label: 'Моё'),
          NavigationDestination(icon: Badge(isLabelVisible: _newUpdateCount > 0,
              label: Text(_newUpdateCount > 99 ? '99+' : _newUpdateCount.toString()),
              child: const Icon(Icons.notifications_outlined)),
            selectedIcon: const Icon(Icons.notifications_active),
            label: 'Уведомления'),
          const NavigationDestination(icon: Icon(Icons.more_horiz),
            selectedIcon: Icon(Icons.more_horiz), label: 'Ещё'),
        ],
        ),
      ),
    );
  }
}


