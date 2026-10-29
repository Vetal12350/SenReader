import 'package:flutter/material.dart';
import '../core/models.dart';
import '../data/catalog_repository.dart';
import '../data/library_store.dart';

/// Search is a suggestion only. Every selection requires an explicit confirmation.
class SourceLinkPage extends StatefulWidget {
  const SourceLinkPage({super.key, required this.book,
    required this.repository, required this.library});
  final UnifiedManga book;
  final CatalogRepository repository;
  final LibraryStore library;
  @override State<SourceLinkPage> createState() => _SourceLinkPageState();
}

class _SourceLinkPageState extends State<SourceLinkPage> {
  late final TextEditingController query;
  CatalogResult? result;
  bool busy = false;
  String? error;
  @override void initState() {
    super.initState();
    query = TextEditingController(text: widget.book.title);
  }
  @override void dispose() { query.dispose(); super.dispose(); }

  Future<void> _search() async {
    setState(() { busy = true; error = null; });
    final next = await widget.repository.getCatalog(query: query.text);
    if (!mounted) return;
    setState(() { result = next; busy = false; });
  }

  Future<void> _link(MangaEntry candidate) async {
    final approved = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Это одно произведение?'),
      content: Text('Связать «${widget.book.title}» с «${candidate.title}»?\n${candidate.source} · ${candidate.id}\nРазные переводы названий не подтверждают совпадение. Избранное и прогресс будут объединены.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Подтвердить связь'))]));
    if (approved != true || !mounted) return;
    setState(() { busy = true; error = null; });
    try {
      await widget.library.connect(widget.book,
        UnifiedManga(title: candidate.title, entries: {candidate.source: candidate}), approved: true);
      if (mounted) Navigator.pop(context, widget.library.get(widget.book)!.toUnified());
    } catch (e) {
      if (mounted) setState(() { error = '$e'; busy = false; });
    }
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Связать источник')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      Text('Название на другом сайте для «${widget.book.title}»'),
      TextField(controller: query, onSubmitted: busy ? null : (_) => _search(),
        decoration: const InputDecoration(labelText: 'Название')),
      FilledButton(onPressed: busy ? null : _search, child: const Text('Найти варианты')),
      if (busy) const LinearProgressIndicator(),
      if (error != null) Text(error!),
      for (final warning in result?.warnings ?? <String>[]) Text(warning),
      for (final candidate in result?.books.expand((b) => b.entries.values) ?? <MangaEntry>[])
        if (!widget.book.entries.containsKey(candidate.source))
          ListTile(title: Text(candidate.title), subtitle: Text('${candidate.source} · ${candidate.id}'),
            onTap: busy ? null : () => _link(candidate)),
    ]),
  );
}
