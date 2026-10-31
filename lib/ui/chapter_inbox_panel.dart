import 'package:flutter/material.dart';
import '../core/chapter_identity.dart';
import '../core/title_matching.dart';
import '../data/catalog_repository.dart';
import '../data/chapter_checker.dart';
import '../data/chapter_inbox_store.dart';
import '../data/chapter_alert_controller.dart';
import '../data/library_store.dart';
import 'reader_page.dart';
import 'widgets.dart';

class ChapterInboxPanel extends StatefulWidget {
  const ChapterInboxPanel({super.key, required this.library, required this.repository,
    required this.alerts, this.onChanged});
  final LibraryStore library;
  final CatalogRepository repository;
  final ChapterAlertController alerts;
  final VoidCallback? onChanged;
  @override State<ChapterInboxPanel> createState() => _ChapterInboxPanelState();
}

class _ChapterInboxPanelState extends State<ChapterInboxPanel> {
  final ChapterInboxStore _store = ChapterInboxStore();
  List<InboxEntry> entries = const [];
  bool hidden = false;
  bool loading = true;
  bool checking = false;
  String? error;
  @override void initState() { super.initState(); _refresh(); }
  Future<void> _refresh() async {
    final next = await _store.load();
    if (mounted) {
      setState(() { entries = next; loading = false; });
      widget.onChanged?.call();
    }
  }

  Future<void> _check() async {
    if (checking) return;
    setState(() { checking = true; error = null; });
    try {
      await widget.library.load();
      final report = await ChapterChecker(repository: widget.repository,
        library: widget.library).check();
      for (final discovery in report.discoveries) {
        await _store.add(normalizedTitle(discovery.book.title),
          discovery.book.title, discovery.book.coverUrl,
          discovery.sourceKey, discovery.chapter);
      }
      await _refresh();
    } catch (_) {
      if (mounted) setState(() => error = 'Не удалось проверить обновления.');
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  Future<void> _open(InboxEntry entry) async {
    await widget.library.load();
    final saved = widget.library.items.where((x) => x.key == entry.bookKey).firstOrNull;
    if (saved == null || saved.preferredSource != entry.source) return;
    final source = widget.repository.sources[entry.source];
    final manga = saved.entries[entry.source];
    if (source == null || manga == null) return;
    try {
      final detail = await source.detail(manga);
      final target = detail.chapters.where((x) => x.id == entry.chapterId).firstOrNull;
      if (!mounted) return;
      if (target == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Глава больше недоступна')));
        return;
      }
      await Navigator.push(context, MaterialPageRoute(builder: (_) => ReaderPage(
        book: saved.toUnified(), chapter: target, sourceKey: entry.source,
        repository: widget.repository, library: widget.library,
        chapters: detail.chapters,
      )));
      await _refresh();
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть главу')));
    }
  }

  @override Widget build(BuildContext context) {
    final visible = entries.where((e) => e.hidden == hidden).toList()
      ..sort((a, b) => (hidden ? b.hiddenAt.compareTo(a.hiddenAt) :
          b.createdAt.compareTo(a.createdAt)));
    return Column(children: [
      Padding(padding: const EdgeInsets.all(12),
        child: Row(children: [
          Expanded(child: SegmentedButton<bool>(
            selected: {hidden}, segments: const [
              ButtonSegment(value: false, label: Text('Новые')),
              ButtonSegment(value: true, label: Text('Скрытые')),
            ], onSelectionChanged: (v) => setState(() => hidden = v.first))),
          IconButton(tooltip: 'Проверить обновления',
            onPressed: checking ? null : _check, icon: Icon(checking
              ? Icons.hourglass_top : Icons.refresh)),
        ])),
      if (error != null) Text(error!),
      if (loading) const Expanded(child: Center(child: CircularProgressIndicator()))
      else Expanded(child: visible.isEmpty
        ? Center(child: Text(hidden ? 'Скрытых обновлений пока нет' :
            'Новых глав пока нет', textAlign: TextAlign.center))
        : ListView.separated(padding: const EdgeInsets.all(12),
          itemCount: visible.length, separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final entry = visible[index];
            return Card(child: ListTile(
              leading: ClipRRect(borderRadius: BorderRadius.circular(7),
                child: CoverImage(entry.coverUrl, width: 48, height: 64)),
              title: Text(entry.title, maxLines: 2),
              subtitle: Text(entry.chapterName),
              trailing: hidden ? const Icon(Icons.visibility_off_outlined)
                : IconButton(tooltip: 'Скрыть обновление',
                    onPressed: () async {
                      await _store.hideEntry(entry.key);
                      await _refresh();
                    }, icon: const Icon(Icons.more_horiz)),
              onTap: () => _open(entry),
            ));
          })),
    ]);
  }
}
