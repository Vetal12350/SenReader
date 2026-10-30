import 'dart:async';
import 'package:flutter/material.dart';
import 'core/models.dart';
import 'core/chapter_identity.dart';
import 'data/catalog_repository.dart';
import 'data/senkuro_source.dart';
import 'data/library_store.dart';
import 'data/reading_suggestions.dart';
import 'data/chapter_notification_service.dart';
import 'data/chapter_background_scheduler.dart';
import 'ui/detail_page.dart';
import 'ui/reader_page.dart';
import 'ui/widgets.dart';
import 'data/chapter_alert_controller.dart';
import 'ui/chapter_alert_offer.dart';
import 'ui/settings_page.dart';
import 'data/theme_controller.dart';
import 'ui/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final library = LibraryStore();
  await library.load();
  try {
    await ChapterNotificationService.instance.initialize();
    await ChapterBackgroundScheduler.initialize();
  } catch (_) {
    // Keep the library usable even if this Android version cannot schedule
    // background checks; manual checking remains available.
  }
  final themes = ThemeController();
  try { await themes.load(); } catch (_) { /* Use the existing dark default. */ }
  runApp(SenReaderApp(library: library, themes: themes));
}

class SenReaderApp extends StatelessWidget {
  const SenReaderApp({super.key, required this.library, required this.themes});
  final LibraryStore library;
  final ThemeController themes;

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
          library: library, themes: themes),
    ),
  );
}

class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.repository, required this.library, this.alerts, this.themes});
  final ChapterAlertController? alerts;
  final ThemeController? themes;
  final CatalogRepository repository;
  final LibraryStore library;
  @override State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int tab = 0;
  String libraryFilter = 'all';
  String catalogSourceFilter = 'all';
  String catalogSort = 'default';
  String? catalogTagFilter;
  CatalogResult? result;
  bool loading = false;
  int _suggestionRequest = 0;
  final Map<String, Chapter> _newChapters = {};
  int _homeRequest = 0;
  final Map<String, List<MangaEntry>> _senkuroSections = {};
  late final ChapterAlertController alerts = widget.alerts ?? ChapterAlertController();
  String query = '';
  Timer? debounce;
  final TextEditingController searchController = TextEditingController();

  @override void initState() {
    super.initState();
    _fetch();
    ChapterNotificationService.instance.openedPayload.addListener(_onNotificationTap);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onNotificationTap());
  }

  @override void dispose() {
    debounce?.cancel();
    ChapterNotificationService.instance.openedPayload.removeListener(_onNotificationTap);
    searchController.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    final thisQuery = query;
    setState(() => loading = true);
    final next = await widget.repository.getCatalog(query: thisQuery);
    if (!mounted || thisQuery != query) return;
    setState(() { result = next; loading = false; });
    unawaited(_refreshNewChapters());
    if (thisQuery.isEmpty) unawaited(_refreshSenkuroSections());
  }

  Future<void> _refreshSenkuroSections() async {
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
    await Future.wait(options.map((option) async {
      try {
        final list = await source.browseHome(
          type: option.$2, orderField: option.$3);
        if (list.isNotEmpty) categories[option.$1] = list;
      } catch (_) {
        // Category-specific failures never hide the regular catalog.
      }
    }));
    if (!mounted || request != _homeRequest) return;
    setState(() => _senkuroSections..clear()..addAll(categories));
  }

  Future<void> _refreshNewChapters() async {
    final request = ++_suggestionRequest;
    final saved = widget.library.items
      .where((item) => item.lastChapter.isNotEmpty &&
        item.lastSource == item.preferredSource && item.status != 'dropped' &&
        item.status != 'viewed').toList()
      ..sort((a, b) => b.lastUpdatedAt.compareTo(a.lastUpdatedAt));
    final suggestions = <String, Chapter>{};
    // Bound parallel calls and avoid bogus update indicators when offline.
    for (var i = 0; i < saved.length && i < 12; i += 3) {
      await Future.wait(saved.skip(i).take(3).map((item) async {
        final entry = item.entries[item.preferredSource];
        final source = widget.repository.sources[item.preferredSource];
        if (entry == null || source == null) return;
        try {
          final detail = await source.detail(entry);
          final fresh = nextAvailableChapter(item, detail.chapters);
          final current = widget.library.get(item.toUnified());
          if (fresh != null && current != null &&
              current.preferredSource == item.preferredSource &&
              current.lastChapterId == item.lastChapterId &&
              current.lastSource == item.lastSource) {
            suggestions[item.key] = fresh;
          }
        } catch (_) {
          // Network failures never produce false-positive suggestions.
        }
      }));
      if (!mounted || request != _suggestionRequest) return;
    }
    if (mounted && request == _suggestionRequest) {
      setState(() { _newChapters..clear()..addAll(suggestions); });
    }
  }

  void _onSearch(String value) {
    query = value;
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 450), _fetch);
  }

  /// Local controls apply to the results returned by the available sources;
  /// they are not a claim of server-wide filtered or chronological ranking.
  List<UnifiedManga> _visibleCatalogBooks() {
    final books = (result?.books ?? const <UnifiedManga>[])
        .where((book) => (catalogSourceFilter == 'all' ||
            book.entries.containsKey(catalogSourceFilter)) &&
          (catalogTagFilter == null || book.entries.values.any(
            (entry) => entry.tags.contains(catalogTagFilter))))
        .toList();
    if (catalogSort == 'titleAsc') {
      books.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    } else if (catalogSort == 'titleDesc') {
      books.sort((a, b) => b.title.toLowerCase().compareTo(a.title.toLowerCase()));
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
    showModalBottomSheet<void>(context: context, isScrollControlled: true,
      useSafeArea: true, builder: (sheetContext) =>
        StatefulBuilder(builder: (sheetContext, setSheet) {
          final tags = _catalogTags.where((tag) =>
            tag.toLowerCase().contains(search.toLowerCase())).toList();
          return FractionallySizedBox(heightFactor: .78,
            child: Padding(padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Expanded(child: Text('Фильтры по тегам',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
                  TextButton(onPressed: () {
                    setState(() => catalogTagFilter = null);
                    setSheet(() {});
                  }, child: const Text('Сбросить')),
                ]),
                const Text('Применяются к загруженному каталогу. '
                  'Метки доступны только для произведений, '
                  'которые передал источник.'),
                const SizedBox(height: 12),
                TextField(onChanged: (v) => setSheet(() => search = v),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Поиск жанра или тега')),
                const SizedBox(height: 12),
                Expanded(child: tags.isEmpty
                  ? const Center(child: Text('Сейчас у загруженных произведений нет меток'))
                  : ListView(children: [
                      Wrap(spacing: 6, runSpacing: 3,
                        children: tags.map((tag) => FilterChip(
                          label: Text(tag),
                          selected: catalogTagFilter == tag,
                          onSelected: (selected) {
                            setState(() => catalogTagFilter = selected ? tag : null);
                            setSheet(() {});
                          },
                        )).toList()),
                    ])),
                SizedBox(width: double.infinity,
                  child: FilledButton(onPressed: () => Navigator.pop(sheetContext),
                    child: Text('Показать ${_visibleCatalogBooks().length} результатов'))),
              ])),
          );
        }),
    );
  }

  Widget _sourceRow(String title, Iterable<UnifiedManga> books) {
    final items = books.take(12).toList();
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(top: 25, bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SectionTitle(title, subtitle: 'Подборка из доступного каталога'),
        const SizedBox(height: 12),
        SingleChildScrollView(scrollDirection: Axis.horizontal,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final book in items) ...[
                SizedBox(width: 116, child: MangaTile(
                  book: book, onTap: () => _open(book))),
                const SizedBox(width: 10),
              ],
            ])),
      ]));
  }

  Widget _homeCollections() {
    final books = result?.books ?? const <UnifiedManga>[];
    final topTags = _catalogTags.where((tag) =>
      books.where((book) => book.entries.values.any(
        (entry) => entry.tags.contains(tag))).length >= 3).take(2);
    return Column(children: [
      for (final section in const [
        'Последние обновления', 'Топ манхв',
        'Топ маньхуа', 'Топ манг',
      ])
        if (_senkuroSections[section]?.isNotEmpty == true)
          _sourceRow(section,
            _senkuroSections[section]!.map((entry) =>
              UnifiedManga(title: entry.title, entries: {'senkuro': entry}))),
      _sourceRow('На ReadManga',
        books.where((book) => book.entries.containsKey('readmanga'))),
      _sourceRow('На ReManga',
        books.where((book) => book.entries.containsKey('remanga'))),
      for (final tag in topTags)
        _sourceRow('По тегу: $tag',
          books.where((book) => book.entries.values.any(
            (entry) => entry.tags.contains(tag)))),
    ]);
  }

  Widget _catalogControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(spacing: 8, runSpacing: 6, children: [
        PopupMenuButton<String>(
          tooltip: 'Фильтр по источнику',
          initialValue: catalogSourceFilter,
          onSelected: (value) => setState(() => catalogSourceFilter = value),
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'all', child: Text('Все источники')),
            PopupMenuItem(value: 'senkuro', child: Text('Senkuro')),
            PopupMenuItem(value: 'readmanga', child: Text('ReadManga')),
            PopupMenuItem(value: 'remanga', child: Text('ReManga')),
          ],
          child: Chip(
            avatar: const Icon(Icons.filter_list, size: 18),
            label: Text(catalogSourceFilter == 'all' ? 'Все источники' :
              catalogSourceFilter == 'senkuro' ? 'Senkuro' :
              catalogSourceFilter == 'readmanga' ? 'ReadManga' : 'ReManga'),
          ),
        ),
        ActionChip(
          key: const Key('catalog-tag-filters'),
          avatar: const Icon(Icons.tune, size: 18),
          label: Text(catalogTagFilter == null ?
            'Фильтры' : 'Тег: $catalogTagFilter'),
          onPressed: _openCatalogTags,
        ),
        PopupMenuButton<String>(
          tooltip: 'Сортировка каталога',
          initialValue: catalogSort,
          onSelected: (value) => setState(() => catalogSort = value),
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'default', child: Text('По умолчанию')),
            PopupMenuItem(value: 'titleAsc', child: Text('Название А-Я')),
            PopupMenuItem(value: 'titleDesc', child: Text('Название Я-А')),
          ],
          child: Chip(
            avatar: const Icon(Icons.sort, size: 18),
            label: Text(catalogSort == 'default' ? 'По умолчанию' :
              catalogSort == 'titleAsc' ? 'Название А-Я' : 'Название Я-А'),
          ),
        ),
      ]),
      Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 12),
        child: Text('Фильтры и сортировка действуют на загруженные результаты',
          style: TextStyle(fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ),
    ],
  );

  void _open(UnifiedManga book) {
    // Viewing is a separate category, not the "В планах" library status.
    unawaited(widget.library.markViewed(book));
    Navigator.push(context, MaterialPageRoute(builder: (_) => DetailPage(
      book: book, repository: widget.repository, library: widget.library, alerts: alerts,
    ))).then((_) {
      if (mounted) unawaited(_refreshNewChapters());
    });
  }

  Future<void> _resume(SavedBook saved, Chapter newChapter) async {
    await widget.library.load();
    final current = widget.library.get(saved.toUnified());
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
      Chapter? target;
      for (final chapter in detail.chapters) {
        if (chapter.id == newChapter.id &&
            nextAvailableChapter(saved, detail.chapters)?.id == chapter.id) {
          target = chapter;
          break;
        }
      }
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
      final saved = widget.library.items
          .where((item) => _newChapters.containsKey(item.key) &&
              item.lastSource == item.preferredSource &&
              item.status != 'dropped').toList()
        ..sort((a, b) => b.lastUpdatedAt.compareTo(a.lastUpdatedAt));
      if (saved.isEmpty) return const SizedBox.shrink();
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 28),
        SectionTitle('Продолжить чтение',
          subtitle: 'Есть новые непрочитанные главы'),
        SizedBox(height: 155, child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: saved.take(12).length,
          separatorBuilder: (context, index) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final item = saved[index];
            return SizedBox(width: 225, child: InkWell(
              onTap: () => _resume(item, _newChapters[item.key]!),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(14)),
                child: Row(children: [
                  ClipRRect(borderRadius: BorderRadius.circular(9),
                    child: CoverImage(item.toUnified().coverUrl,
                      width: 86, height: 130)),
                  const SizedBox(width: 9),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center, children: [
                      Flexible(child: Text(item.title, maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700))),
                      const SizedBox(height: 8),
                      Flexible(child: Text('Новая: ${_newChapters[item.key]!.name}',
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11))),
                      if (item.lastPageCount > 0) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: (item.lastPageIndex + 1) / item.lastPageCount,
                          backgroundColor: Theme.of(context).colorScheme.outlineVariant),
                        const SizedBox(height: 4),
                        Text('Стр. ${item.lastPageIndex + 1}/${item.lastPageCount}',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      ],
                    ],
                  )),
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
    await widget.library.load();
    if (!mounted) return;
    SavedBook? saved;
    for (final book in widget.library.items) {
      if (book.key == info['book']) { saved = book; break; }
    }
    if (saved == null) return;
    final sourceKey = info['source']!;
    if (saved.preferredSource != sourceKey) return;
    final entry = saved.entries[sourceKey];
    final source = widget.repository.sources[sourceKey];
    if (entry == null || source == null) return;
    try {
      final detail = await source.detail(entry);
      await widget.library.load();
      if (widget.library.get(saved.toUnified())?.preferredSource != sourceKey) return;
      Chapter? matched;
      for (final chapter in detail.chapters) {
        if (chapter.id == info['chapter'] &&
            canonicalChapterKey(chapter) == info['canonical']) {
          matched = chapter;
          break;
        }
      }
      if (!mounted) return;
      if (matched == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Глава больше недоступна. Попробуй другой источник.')));
        return;
      }
      Navigator.push(context, MaterialPageRoute(builder: (_) => ReaderPage(
        book: saved!.toUnified(), chapter: matched!,
        sourceKey: sourceKey, repository: widget.repository, library: widget.library, chapters: detail.chapters,
      )));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Не удалось открыть главу. Проверь соединение или доступ.')));
    }
  }

  @override Widget build(BuildContext context) {
    final catalogBooks = tab == 1 ? _visibleCatalogBooks() : result?.books ?? <UnifiedManga>[];
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Icon(Icons.auto_stories_rounded, size: 25, color: Color(0xFFFF893F)),
          const SizedBox(width: 10),
          Expanded(child: Text(tab == 0 ? 'SenReader' : tab == 1 ? 'Каталог' : 'Мои закладки',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800))),
        ]),
        actions: [
          if (tab != 2)
            IconButton(tooltip: 'Обновить', icon: const Icon(Icons.refresh), onPressed: _fetch),
          IconButton(tooltip: 'Настройки', icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage(
              repository: widget.repository, library: widget.library, alerts: alerts,
               themes: widget.themes)))),
        ],
      ),
      body: tab == 2 ? AnimatedBuilder(
        animation: widget.library,
        builder: (context, _) {
          final saved = widget.library.items;
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
                      ('all', 'Все'), ('viewed', 'Открыто'),
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
                      statusLabel: item.favorite ? '♥ Любимое' :
                        item.status == 'reading' ? 'Читаю' :
                        item.status == 'completed' ? 'Прочитано' :
                        item.status == 'dropped' ? 'Заброшено' :
                        item.status == 'viewed' ? 'Открыто' : 'В планах',
                      onTap: () => _open(item.toUnified())),
                  )).toList(),
                )),
              ]);
        },
      ) : RefreshIndicator(
        onRefresh: _fetch,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
          children: [
            if (tab == 0) ...[
              TextField(
                readOnly: true,
                onTap: () => setState(() => tab = 1),
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
              if (!loading && result != null &&
                  result!.senkuroPopular.isNotEmpty)
                // Size the horizontal carousel by its actual tile content,
                // including OS font scaling, rather than a fragile fixed height.
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                    for (final item in result!.senkuroPopular.take(15)) ...[
                      SizedBox(width: 116, child: MangaTile(
                        book: UnifiedManga(title: item.title,
                          entries: {'senkuro': item}),
                        onTap: () => _open(UnifiedManga(title: item.title,
                          entries: {'senkuro': item})),
                      )),
                      const SizedBox(width: 10),
                    ],
                  ]),
                ),
              _continueReading(),
              if (!loading && result != null) _homeCollections(),
              const SizedBox(height: 30),
            ] else ...[
              TextField(
                controller: searchController,
                onChanged: _onSearch,
                decoration: InputDecoration(
                  hintText: 'Название манги, манхвы, маньхуа…',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 18),
              _catalogControls(),
            ],
            SectionTitle(tab == 0 ? 'Общий каталог' :
                  query.isEmpty ? 'Каталог' : 'Результаты поиска',
              subtitle: 'Senkuro · ReadManga · ReManga'),
            if (loading && tab != 0)
              const Padding(padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator())),
            if (result != null && result!.warnings.isNotEmpty)
              ...result!.warnings.map((w) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(w, style: const TextStyle(color: Color(0xFFFFBE80), fontSize: 12)),
              )),
            if (!loading && result != null && catalogBooks.isEmpty)
              const EmptyView(icon: Icons.search_off,
                text: 'По заданным фильтрам ничего не найдено.'),
            if (!loading && result != null && catalogBooks.isNotEmpty)
              LayoutBuilder(builder: (context, box) => Wrap(
                spacing: 10, runSpacing: 18,
                children: catalogBooks.map((book) => SizedBox(
                  width: (box.maxWidth - 20) / 3,
                  child: MangaTile(book: book, onTap: () => _open(book)),
                )).toList(),
              )),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (index) {
          setState(() => tab = index);
          if (index == 2 && widget.library.items.isNotEmpty) {
            unawaited(offerChapterAlerts(context, alerts));
          }
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Главная'),
          NavigationDestination(icon: Icon(Icons.explore_outlined), selectedIcon: Icon(Icons.explore), label: 'Каталог'),
          NavigationDestination(icon: Icon(Icons.bookmarks_outlined), selectedIcon: Icon(Icons.bookmarks), label: 'Библиотека'),
        ],
      ),
    );
  }
}
