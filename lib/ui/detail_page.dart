import 'package:flutter/material.dart';
import '../core/models.dart';
import '../data/catalog_repository.dart';
import '../data/library_store.dart';
import 'reader_page.dart';
import 'widgets.dart';

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
  @override void initState() {
    super.initState();
    book = widget.book;
    selected = book.primary.source;
    _load();
    _discoverOther();
  }

  Future<void> _discoverOther() async {
    final next = await widget.repository.findOtherSources(book);
    if (!mounted) return;
    setState(() => book = next);
    if (widget.library.has(next)) await widget.library.add(next);
    // Discovery may finish after the initial detail request.
    if (mounted && selected == 'senkuro' && next.entries.containsKey('readmanga') &&
        ((detail != null && detail!.chapters.isEmpty) || error != null)) {
      _select('readmanga');
    }
  }

  Future<void> _load() async {
    setState(() { loading = true; error = null; detail = null; });
    try {
      final next = await widget.repository.sources[selected]!.detail(book.entries[selected]!);
      if (!mounted) return;
      setState(() { loading = false; detail = next; });
      // If the primary source has no chapters, look for an existing alternative.
      if (next.chapters.isEmpty && selected == 'senkuro' && book.entries.containsKey('readmanga')) {
        _select('readmanga');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { loading = false; error = '$e'; });
    }
  }

  void _select(String value) {
    if (selected == value) return;
    setState(() => selected = value);
    _load();
  }

  @override Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Произведение'), actions: [
        AnimatedBuilder(animation: widget.library, builder: (context, _) => IconButton(
          tooltip: widget.library.has(book) ? 'Убрать из библиотеки' : 'Добавить в библиотеку',
          icon: Icon(widget.library.has(book) ? Icons.bookmark : Icons.bookmark_outline),
          onPressed: () async {
            if (widget.library.has(book)) { await widget.library.remove(book); }
            else { await widget.library.add(book); }
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
        if (loading) const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())),
        if (error != null) ...[
          Text('Не удалось получить главы: $error', style: const TextStyle(color: Color(0xFFFFBE80))),
          const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('Повторить')),
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
            leading: const Icon(Icons.menu_book_outlined),
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
