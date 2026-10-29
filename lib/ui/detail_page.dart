import 'package:flutter/material.dart';
import '../core/models.dart';
import '../core/chapter_updates.dart';
import '../data/catalog_repository.dart';
import '../data/library_store.dart';
import 'reader_page.dart';
import 'widgets.dart';
import 'source_link_page.dart';
import 'chapter_updates_page.dart';

class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.book, required this.repository, required this.library});
  final UnifiedManga book;
  final CatalogRepository repository;
  final LibraryStore library;
  @override State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late UnifiedManga book;
  late String selected;
  MangaDetail? detail;
  bool loading = true;
  String? error;
  final Set<String> _attempted = {};
  final List<String> _warnings = [];
  int _request = 0;
  @override void initState() {
    super.initState();
    final savedBook = widget.library.get(widget.book);
    book = savedBook == null ? widget.book : UnifiedManga(title: savedBook.title,
      entries: {...savedBook.entries}, savedId: savedBook.id,
      requiresLinkApproval: savedBook.requiresLinkApproval || widget.book.requiresLinkApproval);
    // A catalog group may overlap separately saved titles. Open one favorite and
    // leave their connection to the confirmation flow.
    if (widget.library.get(book) == null) {
      for (final entry in book.entries.values.toList()) {
        final saved = widget.library.get(UnifiedManga(title: entry.title, entries: {entry.source: entry},
          requiresLinkApproval: book.requiresLinkApproval));
        if (saved != null) {
          book = saved.toUnified();
          _warnings.add('Есть отдельно сохранённые источники. Подтвердите связь вручную.');
          break;
        }
      }
    }
    selected = book.primary.source;
    _load();
    _discoverOther();
  }

  Future<void> _discoverOther() async {
    final next = await widget.repository.findOtherSources(book);
    if (!mounted) return;
    final entries = {...next.entries, ...book.entries};
    final current = widget.library.get(book);
    for (final entry in entries.values.toList()) {
      if (book.entries.containsKey(entry.source)) continue;
      final owner = widget.library.get(UnifiedManga(title: entry.title, entries: {entry.source: entry}));
      if (owner != null && owner.id != current?.id) {
        entries.remove(entry.source);
        _warnings.add('${entry.source}: подтвердите связь с отдельным избранным вручную.');
      }
    }
    final discovered = UnifiedManga(title: book.title, entries: entries, savedId: book.savedId,
      requiresLinkApproval: book.requiresLinkApproval);
    setState(() => book = discovered);
    if (widget.library.has(discovered)) {
      try { await widget.library.add(discovered); }
      catch (e) { if (mounted) setState(() => _warnings.add('$e')); }
    }
    // Discovery may finish after the initial detail request.
    if (mounted && !loading && (detail?.chapters.isEmpty == true || error != null)) {
      _fallback();
    }
  }

  Future<void> _load() async {
    final request = ++_request;
    final sourceKey = selected;
    _attempted.add(sourceKey);
    setState(() { loading = true; error = null; detail = null; });
    try {
      final source = widget.repository.sources[sourceKey];
      if (source == null) throw StateError('Источник $sourceKey недоступен');
      final next = await source.detail(book.entries[sourceKey]!);
      if (!mounted || request != _request) return;
      setState(() { loading = false; detail = next; });
      if (next.chapters.isEmpty) {
        setState(() => _warnings.add('${source.name}: публичные главы недоступны.'));
        _fallback();
      }
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        loading = false;
        error = '$e';
        _warnings.add('${widget.repository.sources[sourceKey]?.name ?? sourceKey}: $e');
      });
      _fallback();
    }
  }

  void _fallback() {
    for (final source in book.entries.keys) {
      if (!_attempted.contains(source) && widget.repository.sources.containsKey(source)) {
        setState(() => selected = source);
        _load();
        return;
      }
    }
  }

  void _select(String value) {
    if (selected == value) return;
    setState(() {
      selected = value;
      _attempted.clear();
      _warnings.clear();
    });
    _load();
  }

  void _retry() {
    _attempted.clear();
    _warnings.clear();
    _load();
  }

  @override Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Произведение'), actions: [
        AnimatedBuilder(animation: widget.library, builder: (context, _) => IconButton(
          tooltip: widget.library.has(book) ? 'Убрать из библиотеки' : 'Добавить в библиотеку',
          icon: Icon(widget.library.has(book) ? Icons.bookmark : Icons.bookmark_outline),
          onPressed: () async {
            try {
              if (widget.library.has(book)) { await widget.library.remove(book); }
              else { await widget.library.add(book); }
            } catch (e) {
              if (mounted) setState(() => _warnings.add('$e'));
            }
          },
        )),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(borderRadius: BorderRadius.circular(12), child: CoverImage(
            detail?.entry.coverUrl ?? book.coverUrl, width: 120, height: 170)),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(detail?.entry.title ?? book.title,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            const Text('Источник глав', style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, children: [
              for (final source in book.entries.keys)
                ChoiceChip(
                  label: Text(widget.repository.sources[source]?.name ?? source,
                    style: const TextStyle(fontSize: 12)),
                  selected: selected == source,
                  onSelected: (_) => _select(source),
                ),
            ]),
          ])),
        ]),
        const SizedBox(height: 18),
        OutlinedButton.icon(onPressed: () async {
          final linked = await Navigator.push<UnifiedManga>(context, MaterialPageRoute(builder: (_) => SourceLinkPage(
            book: book, repository: widget.repository, library: widget.library)));
          if (linked != null && mounted) setState(() => book = linked);
        }, icon: const Icon(Icons.link), label: const Text('Связать источник')),
        AnimatedBuilder(animation: widget.library, builder: (context, _) {
          final saved = widget.library.get(book);
          return saved == null ? const SizedBox.shrink() : OutlinedButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChapterUpdatesPage(
              library: widget.library, repository: widget.repository, bookId: saved.id, runOnOpen: true))),
            icon: const Icon(Icons.refresh), label: const Text('Проверить новые главы'));
        }),
        for (final warning in _warnings)
          Text(warning, style: const TextStyle(color: Color(0xFFFFBE80))),
        if (loading) const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())),
        if (error != null) ...[
          Text('Не удалось получить главы: $error', style: const TextStyle(color: Color(0xFFFFBE80))),
          const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: _retry, icon: const Icon(Icons.refresh), label: const Text('Повторить')),
        ],
        if (detail != null) ...[
          if (detail!.genres.isNotEmpty)
            Wrap(spacing: 6, runSpacing: 4, children: detail!.genres.map((g) => Chip(label: Text(g, style: const TextStyle(fontSize: 11)))).toList()),
          if (detail!.description.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(detail!.description, maxLines: 7, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, height: 1.45)),
          ],
          const SizedBox(height: 24),
          SectionTitle('Главы', subtitle: '${detail!.chapters.length} · ${widget.repository.sources[selected]?.name}'),
          if (detail!.chapters.isEmpty)
            const Text('Глав нет или они недоступны. Попробуй другой источник.', style: TextStyle(color: Colors.white60)),
          ...detail!.chapters.map((chapter) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: AnimatedBuilder(animation: widget.library, builder: (context, _) {
              final key = canonicalChapterKey(chapter);
              final read = key != null && (widget.library.get(book)?.progress.any(
                (p) => canonicalChapterKey(p.chapter) == key) ?? false);
              return Icon(read ? Icons.check_circle_outline : Icons.menu_book_outlined);
            }),
            title: Text(chapter.name),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ReaderPage(
              book: book, chapter: chapter, sourceKey: selected,
              repository: widget.repository, library: widget.library,
            ))),
          )),
        ],
      ]),
    );
  }
}
