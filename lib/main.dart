import 'dart:async';
import 'package:flutter/material.dart';
import 'core/models.dart';
import 'data/catalog_repository.dart';
import 'data/chapter_checker.dart';
import 'data/library_store.dart';
import 'ui/detail_page.dart';
import 'ui/reader_page.dart';
import 'ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final library = LibraryStore();
  await library.load();
  runApp(SenReaderApp(library: library));
}

class SenReaderApp extends StatelessWidget {
  const SenReaderApp({super.key, required this.library});
  final LibraryStore library;

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFC6A8FF);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SenReader',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF101015),
        cardColor: const Color(0xFF1C1C23),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF101015)),
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
  }

  @override void dispose() {
    debounce?.cancel();
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
          const Icon(Icons.auto_stories_rounded, size: 25, color: Color(0xFFC6A8FF)),
          const SizedBox(width: 10),
          Text(tab == 0 ? 'SenReader' : tab == 1 ? 'Каталог' : 'Моя библиотека',
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
              const Text('Твои истории — в одном месте', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              const Text('Senkuro + ReadManga + ReManga. Один каталог, одна библиотека.',
                style: TextStyle(color: Colors.white60)),
              const SizedBox(height: 24),
              FilledButton.icon(onPressed: () => setState(() => tab = 1),
                icon: const Icon(Icons.search), label: const Text('Найти мангу или манхву')),
              const SizedBox(height: 24),
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
            SectionTitle(tab == 0 ? 'Популярное' : query.isEmpty ? 'Каталог' : 'Результаты поиска',
              subtitle: 'Приоритет Senkuro · ReadManga · ReManga'),
            if (loading) const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
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
