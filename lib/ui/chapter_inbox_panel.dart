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
    if (saved == null || !saved.entries.containsKey(entry.source)) return;
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

  static String _dateLabel(int millis) {
    if (millis <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}';
  }

  @override Widget build(BuildContext context) {
    final activeCount = entries.where((e) => !e.hidden).length;
    final hiddenCount = entries.length - activeCount;
    final visible = entries.where((e) => e.hidden == hidden).toList()
      ..sort((a, b) => (hidden ? b.hiddenAt.compareTo(a.hiddenAt) :
          b.createdAt.compareTo(a.createdAt)));
    final theme = Theme.of(context);
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.notifications_active_outlined, size: 23),
            const SizedBox(width: 9),
            Expanded(child: Text('Обновления глав',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800))),
            IconButton(tooltip: 'Проверить обновления',
              onPressed: checking ? null : _check,
              icon: Icon(checking ? Icons.hourglass_top : Icons.refresh)),
          ]),
          const SizedBox(height: 4),
          Text('Новости сохранённых произведений',
            style: theme.textTheme.bodySmall),
          const SizedBox(height: 14),
          SizedBox(width: double.infinity, child: SegmentedButton<bool>(
            selected: {hidden}, segments: [
              ButtonSegment(value: false, label: Text('Новые ($activeCount)')),
              ButtonSegment(value: true, label: Text('Скрытые ($hiddenCount)')),
            ], onSelectionChanged: (v) => setState(() => hidden = v.first))),
        ])),
      if (error != null)
        Padding(padding: const EdgeInsets.all(12), child: Text(error!,
          style: TextStyle(color: theme.colorScheme.error))),
      if (loading)
        const Expanded(child: Center(child: CircularProgressIndicator()))
      else Expanded(child: visible.isEmpty
        ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(hidden ? Icons.archive_outlined :
              Icons.notifications_none, size: 42,
              color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 10),
            Text(hidden ? 'Скрытых обновлений пока нет' :
              'Новых глав пока нет', textAlign: TextAlign.center),
            const SizedBox(height: 4),
            if (!hidden) const Text('Нажми обновление, чтобы проверить главы',
              textAlign: TextAlign.center),
          ]))
        : ListView.separated(padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          itemCount: visible.length,
          separatorBuilder: (_, __) => const SizedBox(height: 5),
          itemBuilder: (context, index) {
            final entry = visible[index];
            return Card(clipBehavior: Clip.antiAlias,
              child: InkWell(onTap: () => _open(entry),
                child: Padding(padding: const EdgeInsets.all(10),
                  child: Row(children: [
                    ClipRRect(borderRadius: BorderRadius.circular(9),
                      child: CoverImage(entry.coverUrl, width: 58, height: 78)),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment:
                        CrossAxisAlignment.start, children: [
                      Text(entry.title, maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 5),
                      Text(displayChapterName(entry.chapterName),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 7),
                      Wrap(spacing: 8, crossAxisAlignment:
                          WrapCrossAlignment.center, children: [
                        Text(entry.source == 'senkuro' ? 'Senkuro' :
                          entry.source == 'readmanga' ? 'Дополнительный источник' : 'Удалённый источник',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary)),
                        Text(_dateLabel(entry.createdAt),
                          style: theme.textTheme.labelSmall),
                      ]),
                    ])),
                    IconButton(
                      tooltip: hidden ? 'Вернуть в новые' : 'Скрыть обновление',
                      icon: Icon(hidden ? Icons.unarchive_outlined :
                        Icons.archive_outlined),
                      onPressed: () async {
                        if (hidden) {
                          await _store.restoreEntry(entry.key);
                        } else {
                          await _store.hideEntry(entry.key);
                        }
                        await _refresh();
                      }),
                  ]),
                )));
          })),
    ]);
  }
}
