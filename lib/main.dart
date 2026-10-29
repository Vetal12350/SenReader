import 'dart:async';
import 'package:flutter/material.dart';
import 'core/models.dart';
import 'core/chapter_identity.dart';
import 'data/catalog_repository.dart';
import 'data/chapter_checker.dart';
import 'data/library_store.dart';
import 'data/chapter_notification_service.dart';
import 'data/chapter_background_scheduler.dart';
import 'ui/detail_page.dart';
import 'ui/reader_page.dart';
import 'ui/widgets.dart';
import 'ui/chapter_notifications_panel.dart';

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
  runApp(SenReaderApp(library: library));
}

class SenReaderApp extends StatelessWidget {
  const SenReaderApp({super.key, required this.library});
  final LibraryStore library;

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFFF893F);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SenReader',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF100F14),
        cardColor: const Color(0xFF20191D),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF100F14)),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFF171419),
          indicatorColor: Color(0xFF41281F),
        ),
      ),
      home: MainShell(repository: CatalogRepository(), library: library),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.repository, required this.library});
  final CatalogRepository repository;
  final LibraryStore library;
  @override State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int tab = 0;
  CatalogResult? result;
  bool loading = false;
  bool checkingChapters = false;
  ChapterScanReport? chapterReport;
  String? checkError;
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
  }

  void _onSearch(String value) {
    query = value;
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 450), _fetch);
  }

  void _open(UnifiedManga book) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => DetailPage(
      book: book, repository: widget.repository, library: widget.library,
    )));
  }

  Future<void> _resume(SavedBook saved) async {
    final book = saved.toUnified();
    final entry = saved.entries[saved.lastSource];
    final source = widget.repository.sources[saved.lastSource];
    if (entry == null || source == null || saved.lastChapter.isEmpty) {
      _open(book);
      return;
    }
    try {
      final detail = await source.detail(entry);
      Chapter? target;
      for (final chapter in detail.chapters) {
        if ((saved.lastChapterId.isNotEmpty && chapter.id == saved.lastChapterId) ||
            (saved.lastChapterId.isEmpty && chapter.name == saved.lastChapter)) {
          target = chapter;
          break;
        }
      }
      if (!mounted) return;
      if (target == null) {
        _open(book);
      } else {
        Navigator.push(context, MaterialPageRoute(builder: (_) => ReaderPage(
          book: book, chapter: target!, sourceKey: saved.lastSource,
          repository: widget.repository, library: widget.library,
        )));
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
          .where((item) => item.lastChapter.isNotEmpty).toList()
        ..sort((a, b) => b.lastUpdatedAt.compareTo(a.lastUpdatedAt));
      if (saved.isEmpty) return const SizedBox.shrink();
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 28),
        SectionTitle('Продолжить чтение',
          subtitle: 'Твоя сохранённая глава и страница'),
        SizedBox(height: 155, child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: saved.take(12).length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final item = saved[index];
            return SizedBox(width: 225, child: InkWell(
              onTap: () => _resume(item),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF211B20),
                  borderRadius: BorderRadius.circular(14)),
                child: Row(children: [
                  ClipRRect(borderRadius: BorderRadius.circular(9),
                    child: CoverImage(item.toUnified().coverUrl,
                      width: 86, height: 130)),
                  const SizedBox(width: 9),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center, children: [
                      Text(item.title, maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Text(item.lastChapter,
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70,
                          fontSize: 11)),
                      if (item.lastPageCount > 0) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: (item.lastPageIndex + 1) / item.lastPageCount,
                          backgroundColor: Colors.white12),
                        const SizedBox(height: 4),
                        Text('Стр. ${item.lastPageIndex + 1}/${item.lastPageCount}',
                          style: const TextStyle(fontSize: 10,
                            color: Colors.white60)),
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

  Future<void> _checkChapters() async {
    if (checkingChapters || widget.library.items.isEmpty) return;
    setState(() { checkingChapters = true; checkError = null; chapterReport = null; });
    try {
      final result = await ChapterChecker(
        repository: widget.repository, library: widget.library,
      ).check();
      if (!mounted) return;
      setState(() { checkingChapters = false; chapterReport = result; });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        checkingChapters = false;
        checkError = 'Не удалось завершить проверку глав. Попробуй позже.';
      });
    }
  }

  Future<void> _onNotificationTap() async {
    final state = ChapterNotificationService.instance.openedPayload;
    final payload = state.value;
    if (payload == null || !mounted) return;
    state.value = null; // Never re-open on UI rebuild.
    final info = ChapterNotificationService.decodePayload(payload);
    if (info == null) return;
    SavedBook? saved;
    for (final book in widget.library.items) {
      if (book.key == info['book']) { saved = book; break; }
    }
    if (saved == null) return;
    final sourceKey = info['source']!;
    final entry = saved.entries[sourceKey];
    final source = widget.repository.sources[sourceKey];
    if (entry == null || source == null) return;
    try {
      final detail = await source.detail(entry);
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
        sourceKey: sourceKey, repository: widget.repository, library: widget.library,
      )));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Не удалось открыть главу. Проверь соединение или доступ.')));
    }
  }

  void _openChapter(ChapterDiscovery discovery) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => ReaderPage(
      book: discovery.book, chapter: discovery.chapter,
      sourceKey: discovery.sourceKey,
      repository: widget.repository, library: widget.library,
    )));
  }

  @override Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Icon(Icons.auto_stories_rounded, size: 25, color: Color(0xFFFF893F)),
          const SizedBox(width: 10),
          Text(tab == 0 ? 'SenReader' : tab == 1 ? 'Каталог' : 'Мои закладки',
            style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
        actions: [
          IconButton(tooltip: tab == 2 ? 'Проверить новые главы' : 'Обновить',
            icon: const Icon(Icons.refresh),
            onPressed: tab == 2 ? (checkingChapters ? null : _checkChapters) : _fetch),
        ],
      ),
      body: tab == 2 ? AnimatedBuilder(
        animation: widget.library,
        builder: (context, _) {
          final saved = widget.library.items;
          return saved.isEmpty
            ? const EmptyView(icon: Icons.bookmark_border, text: 'Здесь появятся сохранённые тайтлы')
            : ListView(padding: const EdgeInsets.all(16), children: [
                SectionTitle('Продолжить чтение', subtitle: '${saved.length} в библиотеке'),
                const ChapterNotificationsPanel(),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: checkingChapters ? null : _checkChapters,
                  icon: checkingChapters
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.notifications_active_outlined),
                  label: Text(checkingChapters ? 'Проверяем источники…' : 'Проверить новые главы'),
                ),
                const SizedBox(height: 8),
                if (checkError != null)
                  Text(checkError!, style: const TextStyle(color: Color(0xFFFFBE80))),
                if (chapterReport != null) ...[
                  Text(chapterReport!.discoveries.isEmpty
                      ? 'Новых доступных глав нет. Первая проверка сохраняет исходное состояние.'
                      : 'Найдено новых глав: ${chapterReport!.discoveries.length}',
                    style: const TextStyle(color: Colors.white70)),
                  for (final discovery in chapterReport!.discoveries)
                    ListTile(
                      leading: const Icon(Icons.auto_stories),
                      title: Text(discovery.book.title),
                      subtitle: Text('${discovery.chapter.name} · ${discovery.sourceKey}'),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () => _openChapter(discovery),
                    ),
                  for (final warning in chapterReport!.warnings.take(8))
                    Padding(padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text(warning,
                        style: const TextStyle(color: Color(0xFFFFBE80), fontSize: 12))),
                  const Divider(),
                ],
                ...saved.map((item) => ListTile(
                  contentPadding: const EdgeInsets.symmetric(vertical: 6),
                  leading: ClipRRect(borderRadius: BorderRadius.circular(6),
                    child: CoverImage(item.toUnified().coverUrl, width: 54, height: 76)),
                  title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(item.lastChapter.isEmpty ? 'Ещё не читали' : 'Последняя: ${item.lastChapter}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(item.toUnified()),
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
                SizedBox(height: 197, child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: result!.senkuroPopular.take(15).length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final item = result!.senkuroPopular[index];
                    final book = UnifiedManga(title: item.title,
                        entries: {'senkuro': item});
                    return SizedBox(width: 116,
                      child: MangaTile(book: book, onTap: () => _open(book)));
                  },
                )),
              _continueReading(),
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
            if (!loading && result != null && result!.books.isEmpty)
              const EmptyView(icon: Icons.search_off, text: 'Ничего не найдено или источники недоступны.'),
            if (!loading && result != null && result!.books.isNotEmpty)
              LayoutBuilder(builder: (context, box) => Wrap(
                spacing: 10, runSpacing: 18,
                children: result!.books.map((book) => SizedBox(
                  width: (box.maxWidth - 20) / 3,
                  child: MangaTile(book: book, onTap: () => _open(book)),
                )).toList(),
              )),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (index) => setState(() => tab = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Главная'),
          NavigationDestination(icon: Icon(Icons.explore_outlined), selectedIcon: Icon(Icons.explore), label: 'Каталог'),
          NavigationDestination(icon: Icon(Icons.bookmarks_outlined), selectedIcon: Icon(Icons.bookmarks), label: 'Библиотека'),
        ],
      ),
    );
  }
}
