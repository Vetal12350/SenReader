import 'dart:async';
import 'package:flutter/material.dart';
import '../core/chapter_identity.dart';
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
  Timer? _poll;
  bool _refreshing = false;
  String? _displayedProfile;
  ChapterInboxStore get _store => ChapterInboxStore(
      profileId: _displayedProfile ?? widget.library.profileId);
  List<InboxEntry> entries = const [];
  bool hidden = false;
  bool loading = true;
  bool checking = false;
  String? error;
  String? lastScanSummary;
  List<String> lastScanDetails = const [];
  @override void initState() {
    super.initState();
    _displayedProfile = widget.library.profileId;
    widget.library.addListener(_libraryChanged);
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    _refresh();
  }
  void _libraryChanged() {
    if (!mounted || _displayedProfile == widget.library.profileId) return;
    // LibraryStore notifies after every scan save/load. Only an actual UID
    // switch should trigger a full SQLite inbox reload; otherwise large
    // background scans would create hundreds of redundant refreshes.
    setState(() {
      _displayedProfile = widget.library.profileId;
      entries = const [];
      loading = true;
      lastScanSummary = null;
    });
    _refresh();
  }
  @override void dispose() {
    _poll?.cancel();
    widget.library.removeListener(_libraryChanged);
    super.dispose();
  }
  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
    final profile = widget.library.profileId;
    final next = await ChapterInboxStore(profileId: profile).load();
    if (mounted && widget.library.profileId == profile) {
      setState(() {
        _displayedProfile = profile; entries = next; loading = false;
      });
      widget.onChanged?.call();
    }
      } finally { _refreshing = false; }
  }

  Future<void> _check() async {
    if (checking) return;
    setState(() { checking = true; error = null; });
    try {
      await widget.library.load();
      final report = await ChapterChecker(repository: widget.repository,
        library: widget.library).check(diagnostics: true);
      if (mounted) setState(() {
        lastScanSummary = 'Проверено книг: ${report.checkedTitles}, '
            'новых глав: ${report.discoveries.length}, '
            'предупреждений: ${report.warnings.length}';
        lastScanDetails = [...report.diagnostics, ...report.warnings];
      });
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
      if (lastScanSummary != null)
        Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(lastScanSummary!, style: theme.textTheme.bodySmall),
              if (lastScanDetails.isNotEmpty)
                TextButton.icon(
                  icon: const Icon(Icons.receipt_long_outlined, size: 18),
                  label: const Text('Отчёт о проверке'),
                  onPressed: () => showModalBottomSheet<void>(
                    context: context, isScrollControlled: true,
                    builder: (context) => SafeArea(child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Text('Проверка источников',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 12),
                        Flexible(child: SingleChildScrollView(child:
                          SelectableText(lastScanDetails.join('\n\n')))),
                        const SizedBox(height: 8),
                      ]),
                    )),
                  ),
                ),
            ],
          ),
        ),
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
                          entry.source == 'readmanga' ? 'ReadManga' : 'Удалённый источник',
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


