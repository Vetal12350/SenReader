import 'package:flutter/material.dart';
import '../core/chapter_updates.dart';
import '../data/catalog_repository.dart';
import '../data/chapter_checker.dart';
import '../data/library_store.dart';
import 'reader_page.dart';

class ChapterUpdatesPage extends StatefulWidget {
  const ChapterUpdatesPage({super.key, required this.library,
    required this.repository, this.bookId, this.runOnOpen = false});
  final LibraryStore library;
  final CatalogRepository repository;
  final String? bookId;
  final bool runOnOpen;
  @override State<ChapterUpdatesPage> createState() => _ChapterUpdatesPageState();
}

class _ChapterUpdatesPageState extends State<ChapterUpdatesPage> {
  bool checking = false;
  String? summary;
  final Map<String, ChapterCheckResult> results = {};

  @override void initState() {
    super.initState();
    if (widget.runOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _check(); });
    }
  }

  Future<void> _check() async {
    if (checking) return;
    setState(() { checking = true; summary = null; results.clear(); });
    var added = 0;
    var baselines = 0;
    var successful = 0;
    try {
      for (final saved in widget.library.items) {
        if (widget.bookId != null && saved.id != widget.bookId) continue;
        final result = await widget.library.check(saved.id, ChapterChecker(widget.repository.sources));
        if (!mounted) return;
        results[saved.id] = result;
        added += result.newChapters.length;
        successful += result.successfulSources;
        if (!saved.updates.initialized && result.state.initialized) baselines++;
      }
      if (mounted) setState(() => summary = successful == 0
        ? 'Источники недоступны или библиотека пуста. Сохранённые данные не сброшены.'
        : 'Новых глав: $added. Начальная проверка: $baselines. Старые главы при первой проверке не добавляются.');
    } catch (e) {
      if (mounted) setState(() => summary = 'Проверка не сохранена: $e');
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  void _open(SavedBook saved, ChapterRelease release) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => ReaderPage(
      book: saved.toUnified(), chapter: release.chapter, sourceKey: release.source,
      repository: widget.repository, library: widget.library)));
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Новые главы')),
    body: AnimatedBuilder(animation: widget.library, builder: (context, _) => ListView(
      padding: const EdgeInsets.all(16), children: [
        FilledButton.icon(onPressed: checking ? null : _check,
          icon: const Icon(Icons.refresh), label: const Text('Проверить новые главы')),
        const Text('Проверяются только связанные источники. Источник выбирается по первому обнаруженному доступу, а не по времени публикации.'),
        if (checking) const LinearProgressIndicator(),
        if (summary != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(summary!)),
        for (final saved in widget.library.items)
          if (widget.bookId == null || widget.bookId == saved.id) ...[
            Text(saved.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            if (saved.updates.inbox.isEmpty) const Text('Нет сохранённых новых глав.'),
            for (final warning in results[saved.id]?.warnings ?? <String>[])
              Text(warning, style: const TextStyle(color: Color(0xFFFFBE80))),
            for (final release in saved.updates.inbox.values) ...[
              ListTile(contentPadding: EdgeInsets.zero,
                title: Text(release.chapter.name),
                subtitle: Text('Первым обнаружен: ${widget.repository.sources[release.source]?.name ?? release.source}'),
                trailing: const Icon(Icons.menu_book),
                onTap: () => _open(saved, release)),
              // Preserve the original detection and allow opening a later copy.
              for (final alternative in results[saved.id]?.available[release.key] ?? <ChapterRelease>[])
                if (alternative.source != release.source || alternative.chapter.id != release.chapter.id)
                  TextButton(onPressed: () => _open(saved, alternative),
                    child: Text('Открыть ${widget.repository.sources[alternative.source]?.name ?? alternative.source} · ${alternative.chapter.name}')),
            ],
            const SizedBox(height: 16),
          ],
      ],
    )),
  );
}
