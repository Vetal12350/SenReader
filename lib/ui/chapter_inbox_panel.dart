import 'dart:async';
import 'package:flutter/material.dart';
import '../core/chapter_identity.dart';
import '../data/catalog_repository.dart';
import '../data/chapter_scan_runner.dart';
import '../data/chapter_inbox_store.dart';
import '../data/chapter_alert_controller.dart';
import '../data/library_store.dart';
import 'notification_navigation.dart';
import 'widgets.dart';

class ChapterInboxPanel extends StatefulWidget {
  const ChapterInboxPanel({super.key, required this.library, required this.repository,
    required this.alerts, this.onChanged, this.inboxStore});
  final LibraryStore library;
  final CatalogRepository repository;
  final ChapterAlertController alerts;
  final VoidCallback? onChanged;
  final ChapterInboxStore? inboxStore;
  @override State<ChapterInboxPanel> createState() => _ChapterInboxPanelState();
}

class _ChapterInboxPanelState extends State<ChapterInboxPanel> {
  Timer? _poll;
  bool _refreshing = false;
  int _revision = 0;
  bool _refreshRequested = false;
  String? _displayedProfile;
  ChapterInboxStore get _store => widget.inboxStore ?? ChapterInboxStore(
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
    // The worker writes SQLite from another isolate; refresh local data
    // without making network requests or rebuilding the list unnecessarily.
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _refresh());
    _refresh();
  }
  void _libraryChanged() {
    if (!mounted || _displayedProfile == widget.library.profileId) return;
    // LibraryStore notifies after every scan save/load. Only an actual UID
    // switch should trigger a full SQLite inbox reload; otherwise large
    // background scans would create hundreds of redundant refreshes.
    setState(() {
      _revision++;
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
    if (_refreshing) { _refreshRequested = true; return; }
    _refreshing = true;
    final revision = _revision;
    try {
    final profile = widget.library.profileId;
    final next = await (widget.inboxStore ?? ChapterInboxStore(profileId: profile)).load();
    if (mounted && revision == _revision && widget.library.profileId == profile) {
      var changed = loading || _displayedProfile != profile ||
          next.length != entries.length;
      if (!changed) {
        for (var i = 0; i < next.length; i++) {
          if (next[i].key != entries[i].key ||
              next[i].hiddenAt != entries[i].hiddenAt ||
              next[i].readAt != entries[i].readAt ||
              next[i].deletedAt != entries[i].deletedAt ||
              next[i].chapterName != entries[i].chapterName) {
            changed = true;
            break;
          }
        }
      }
      if (changed) {
        setState(() {
          _displayedProfile = profile; entries = next; loading = false;
        });
        widget.onChanged?.call();
      }
    }
      } finally {
        _refreshing = false;
        if (mounted && (_refreshRequested || revision != _revision)) {
          _refreshRequested = false;
          unawaited(_refresh());
        }
      }
  }

  Future<void> _check() async {
    if (checking) return;
    setState(() { checking = true; error = null; });
    try {
      final report = await ChapterScanRunner(repository: widget.repository,
        library: widget.library, preferences: widget.alerts.preferences)
          .checkManual(diagnostics: true);
      if (mounted) setState(() {
        lastScanSummary = 'Проверено книг: ${report.checkedTitles}, '
            'обновлено: ${report.updatedTitles}, '
            'новых глав: ${report.discoveries.length}, '
            'предупреждений: ${report.warnings.length}'
            '${report.skippedSources > 0 ? ', уже проверяются: ${report.skippedSources}' : ''}';
        lastScanDetails = [...report.diagnostics, ...report.warnings];
      });
      await _refresh();
    } catch (_) {
      if (mounted) setState(() => error = 'Не удалось проверить обновления.');
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  Future<void> _open(InboxEntry entry, {bool chapter = true}) async {
    await openChapterNotification(context, fields: {
      'book': entry.bookKey, 'source': entry.source, 'chapter': entry.chapterId,
      if (entry.sourceId.isNotEmpty) 'titleId': entry.sourceId,
      'profile': _displayedProfile ?? widget.library.profileId,
      'action': chapter ? 'chapter' : 'title',
    }, library: widget.library, repository: widget.repository, alerts: widget.alerts);
    await _refresh();
  }

  static String _dateLabel(int millis) {
    if (millis <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}';
  }

  @override Widget build(BuildContext context) {
    final visible = entries.where((e) => !e.deleted && !e.read && e.hidden == hidden)
      .toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
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
              ButtonSegment(value: false, label: Text('Новые')),
              ButtonSegment(value: true, label: Text('Скрытые')),
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
            final chapter = displayChapterName(entry.chapterName);
            final button = chapter.startsWith('Глава ')
                ? 'К главе ${chapter.substring(6)}' : 'К главе';
            return Card(clipBehavior: Clip.antiAlias,
              child: InkWell(onTap: () => _open(entry, chapter: false),
                child: Padding(padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    ClipRRect(borderRadius: BorderRadius.circular(9),
                      child: CoverImage(entry.coverUrl, width: 48, height: 66)),
                    const SizedBox(width: 12),
                    Expanded(child: Text(entry.title, maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700))),
                    PopupMenuButton<String>(
                      tooltip: 'Действия с уведомлением',
                      icon: const Icon(Icons.more_horiz),
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 'visibility', child: Text(hidden
                          ? 'Вернуть в новые' : 'Скрыть уведомление')),
                        const PopupMenuItem(value: 'delete', child: Text('Удалить уведомление')),
                      ],
                      onSelected: (action) async {
                        final store = _store;
                        _revision++;
                        if (action == 'delete') {
                          await store.deleteEntry(entry.key);
                        } else if (hidden) {
                          await store.restoreEntry(entry.key);
                        } else {
                          await store.hideEntry(entry.key);
                        }
                        await _refresh();
                      },
                    ),
                  ]),
                  const SizedBox(height: 10),
                  const Text('Вышла новая глава'),
                  const SizedBox(height: 4),
                  Text(chapter),
                  const SizedBox(height: 8),
                  Row(children: [
                    Flexible(child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: Colors.blue.shade700,
                        foregroundColor: Colors.white),
                      onPressed: () => _open(entry),
                      child: Text(button, maxLines: 2, overflow: TextOverflow.ellipsis),
                    )),
                    const SizedBox(width: 12),
                    const Spacer(),
                    Text(_dateLabel(entry.createdAt), style: theme.textTheme.labelSmall),
                  ]),
                ]),
              )));
          })),
    ]);
  }
}



