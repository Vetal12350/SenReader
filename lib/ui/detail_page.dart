import 'dart:async';
import 'package:flutter/material.dart';
import '../core/models.dart';
import '../core/chapter_identity.dart';
import '../data/catalog_repository.dart';
import '../data/library_store.dart';
import '../core/title_metadata.dart';
import '../data/similar_titles.dart';
import '../data/chapter_alert_controller.dart';
import 'chapter_alert_offer.dart';
import 'reader_page.dart';
import 'widgets.dart';

class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.book, required this.repository, required this.library, this.alerts});
  final ChapterAlertController? alerts;
  final UnifiedManga book;
  final CatalogRepository repository;
  final LibraryStore library;
  @override State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late UnifiedManga book;
  late String selected;
  MangaDetail? detail;
  Future<List<MangaEntry>>? _similarFuture;
  bool loading = true;
  String? error;
  String? _loadedDetailSource;
  Timer? _recoveryTimer;
  int _automaticRetries = 0;
  bool showChapters = true;
  bool _descriptionExpanded = false;
  bool newestFirst = true;
  final Set<String> _attempted = {};
  final List<String> _warnings = [];
  int _request = 0;
  Future<void>? _firstLoad;
  late final ChapterAlertController alerts = widget.alerts ?? ChapterAlertController();
  @override void initState() {
    super.initState();
    final saved = widget.library.get(widget.book);
    book = UnifiedManga(title: saved?.title ?? widget.book.title,
      entries: {...widget.book.entries, ...?saved?.entries});
    selected = saved?.preferredSource ?? SavedBook.chooseSource(book.entries);
    _firstLoad = _load();
    // Do not launch two other-source searches on every reopen of a saved title.
    if (saved == null || saved.lastChapter.isEmpty || saved.entries.length < 2) {
      _discoverOther();
    }
  }

  Future<void> _discoverOther() async {
    try {
      final next = await widget.repository.findOtherSources(book);
      if (!mounted) return;
      setState(() => book = next);
      if (widget.library.has(next)) await widget.library.add(next);
      // Do not race the first detail request or duplicate fallback retries.
      await _firstLoad;
      if (!mounted) return;
      // Auto-select only before the first saved reading position. Never
      // project an existing page index onto a different translation.
      final saved = widget.library.get(next);
      if (_attempted.length == 1 &&
          detail?.chapters.isNotEmpty == true &&
          (saved?.lastChapter.isEmpty ?? true)) {
        final preferred = await widget.repository.mostCompleteSource(
            next, selected);
        if (mounted && preferred != selected &&
            (widget.library.get(next)?.lastChapter.isEmpty ?? true)) {
          if (saved != null) {
            await widget.library.setPreferredSource(next, preferred);
          }
          if (!mounted) return;
          setState(() => selected = preferred);
          unawaited(_load());
        }
      }
      if (mounted && !loading && (detail?.chapters.isEmpty == true ||
          (error != null && !widget.repository.sources.containsKey(selected)))) {
        _fallback();
      }
    } catch (_) {
      // Optional source discovery must not break the detail screen.
    }
  }

  @override void dispose() {
    _recoveryTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    final sourceKey = selected;
    _attempted.add(sourceKey);
    setState(() {
      loading = true;
      error = null;
      // A refresh must not discard chapters already loaded from this source.
      if (_loadedDetailSource != sourceKey) detail = null;
      _similarFuture = null;
    });
    try {
      final source = widget.repository.sources[sourceKey];
      if (source == null) throw StateError('Источник $sourceKey недоступен');
      final next = await source.detail(book.entries[sourceKey]!);
      if (!mounted || request != _request) return;
      _recoveryTimer?.cancel();
      _automaticRetries = 0;
      _loadedDetailSource = sourceKey;
      setState(() { loading = false; detail = next; });
      // Preserve source-backed score on previously saved cards. Serialize
      // these metadata writes so they cannot overwrite reading progress.
      unawaited(() async {
        try {
          if (sourceKey == 'senkuro') {
            await widget.library.updateVerifiedRatings([next.entry]);
          }
          await widget.library.recordLatestChapter(book, sourceKey, next.chapters);
        } catch (_) {
          // Metadata refresh must not prevent the title from opening.
        }
      }());
      if (next.chapters.isEmpty) {
        _warnings.add('${source.name}: публичные главы недоступны.');
        _fallback();
      }
    } catch (e) {
      if (!mounted || request != _request) return;
      final unsupported = !widget.repository.sources.containsKey(sourceKey);
      final failure = e.toString().toLowerCase();
      final transient = failure.contains('429') ||
          failure.contains('временно ограничил') ||
          failure.contains('timeout') || failure.contains('time out') ||
          failure.contains('нет соединения') ||
          failure.contains('socketexception');
      final retry = !unsupported && transient && _automaticRetries < 2;
      if (retry) {
        _automaticRetries++;
        _recoveryTimer?.cancel();
        _recoveryTimer = Timer(Duration(seconds: 15 * _automaticRetries), () {
          if (mounted && selected == sourceKey) unawaited(_load());
        });
      }
      setState(() {
        // Show a spinner only before the first successful chapter list.
        loading = retry && detail == null;
        // Never show raw HTTP/GraphQL/Socket errors to readers.
        error = unsupported ? 'Источник недоступен' :
            retry || detail != null ? null : 'Временная ошибка';
      });
      if (unsupported) _fallback();
    }
  }

  void _fallback() {
    if (widget.library.get(book)?.lastChapter.isNotEmpty == true) return;
    for (final source in book.entries.keys) {
      if (!_attempted.contains(source) && widget.repository.sources.containsKey(source)) {
        setState(() => selected = source);
        if (widget.library.has(book)) {
          unawaited(widget.library.setPreferredSource(book, source));
        }
        unawaited(_load());
        return;
      }
    }
  }

  /// An optional, label-based discovery block from real Senkuro catalog data.
  /// A shared label is not an official franchise/series relation.
  Future<List<MangaEntry>> _findSimilar(MangaDetail current) async {
    if (current.genres.isEmpty) return const [];
    final source = widget.repository.sources['senkuro'];
    if (source == null) return const [];
    try {
      return similarBySourceTags(book.title, current.genres, await source.popular());
    } catch (_) {
      return const [];
    }
  }

  Widget _similarSection(MangaDetail current) {
    _similarFuture ??= _findSimilar(current);
    return FutureBuilder<List<MangaEntry>>(future: _similarFuture,
      builder: (context, snapshot) {
        final entries = snapshot.data ?? const <MangaEntry>[];
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 20),
          const Text('Похожие по тегам', style: TextStyle(
            fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 5),
          Text('Подборка из доступного каталога Senkuro, не официальные связи',
            style: TextStyle(fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          if (snapshot.connectionState != ConnectionState.done)
            const LinearProgressIndicator()
          else if (entries.isEmpty)
            Text('Совпадений по меткам пока нет',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant))
          else
            SingleChildScrollView(scrollDirection: Axis.horizontal,
              child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final entry in entries) ...[
                    SizedBox(width: 116, child: MangaTile(
                      book: UnifiedManga(title: entry.title,
                        entries: {'senkuro': entry}),
                      onTap: () {
                        final recommendation = UnifiedManga(
                          title: entry.title, entries: {'senkuro': entry});
                         Navigator.push(context, MaterialPageRoute(
                          builder: (_) => DetailPage(
                            book: recommendation,
                            repository: widget.repository,
                            library: widget.library, alerts: alerts)));
                      },
                    )),
                    const SizedBox(width: 10),
                  ],
                ])),
        ]);
      });
  }


  static String _chapterDate(DateTime date) {
    final local = date.toLocal();
    return '${local.day.toString().padLeft(2, '0')}.' +
        '${local.month.toString().padLeft(2, '0')}.' +
        '${local.year.toString().substring(2)}';
  }

  static String chapterVolume(Chapter chapter) {
    final m = RegExp(r'\(\s*т\.\s*([0-9]+(?:\.[0-9]+)?)\s*\)')
        .firstMatch(chapter.name);
    return m == null ? 'Главы без тома' : 'Том ' + m.group(1)!;
  }

  void _openChapter(Chapter chapter) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => ReaderPage(
      book: book, chapter: chapter, sourceKey: selected,
      repository: widget.repository, library: widget.library,
      chapters: detail!.chapters,
    )));
  }

  Chapter? _startChapter() {
    final chapters = detail?.chapters ?? const <Chapter>[];
    if (chapters.isEmpty) return null;
    final chronological = chapters.where(
      (chapter) => canonicalChapterKey(chapter) != null).toList()
      ..sort((a, b) => compareChapterChronology(a, b)!);
    return chronological.isNotEmpty ? chronological.first : chapters.last;
  }

  Widget _readingAction() => AnimatedBuilder(
    animation: widget.library,
    builder: (context, _) {
      final saved = widget.library.get(book);
      Chapter? target;
      if (detail != null && saved != null && saved.lastSource == selected) {
        for (final chapter in detail!.chapters) {
          if ((saved.lastChapterId.isNotEmpty &&
                chapter.id == saved.lastChapterId) ||
              (saved.lastChapterId.isEmpty &&
                chapter.name == saved.lastChapter)) {
            target = chapter;
            break;
          }
        }
      }
      target ??= _startChapter();
      final isResume = saved != null && saved.lastChapter.isNotEmpty &&
          saved.lastSource == selected;
      final chapterNumber = target == null ? null
          : RegExp(r'Глава\s+([^\s:(]+)').firstMatch(target.name)?.group(1);
      final buttonText = isResume
          ? chapterNumber == null ? 'Продолжить чтение'
              : 'Продолжить $chapterNumber главу'
          : 'Читать';
      return Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 8),
        child: SizedBox(width: double.infinity, child: FilledButton.icon(
          key: const Key('title-read-button'),
          onPressed: target == null ? null : () => _openChapter(target!),
          icon: const Icon(Icons.menu_book_rounded),
          label: Text(buttonText),
        )),
      );
    },
  );

  static String _creditRole(String role) => switch (role.toUpperCase()) {
    'AUTHOR' || 'WRITER' || 'STORY' => 'Сюжет',
    'ARTIST' || 'ILLUSTRATOR' || 'ART' => 'Иллюстрации',
    _ => role,
  };

  /// Build only visible chapter rows, even for thousands of chapters.
  Widget _chapterTile(Chapter chapter) {
    return AnimatedBuilder(
                animation: widget.library,
                builder: (context, _) {
                  final read = widget.library.isChapterRead(book, chapter, selected);
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: IconButton(
                      tooltip: read ? 'Прочитано: отметить непрочитанной' :
                          'Не прочитано: прочитать эту и все предыдущие главы',
                      icon: Icon(read ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                        color: read ? Theme.of(context).colorScheme.primary :
                            Theme.of(context).colorScheme.onSurfaceVariant),
                      onPressed: () async {
                        if (read) {
                          await widget.library.unmarkRead(book, chapter, selected,
                            availableChapters: detail!.chapters);
                        } else {
                          await widget.library.markRead(book, chapter, selected,
                            availableChapters: detail!.chapters,
                            userInitiated: true);
                        }
                      },
                    ),
                    title: Text(displayChapterName(chapter.name),
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: read ? Theme.of(context).colorScheme.onSurfaceVariant : null)),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (chapter.publishedAt != null) ...[
                        Text(_chapterDate(chapter.publishedAt!),
                          style: TextStyle(fontSize: 11,
                            color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        const SizedBox(width: 6),
                      ],
                      const Icon(Icons.chevron_right),
                    ]),
                    onTap: () => _openChapter(chapter),
                  );
                },
              );
  }

  @override Widget build(BuildContext context) {
    final chapterResults = detail?.chapters ?? const <Chapter>[];
    // Non-chapter content is small; chapter rows are created on demand below.
    final staticContent = <Widget>[
        const SizedBox(height: 10),
        Center(child: ClipRRect(borderRadius: BorderRadius.circular(16),
          child: CoverImage(detail?.entry.coverUrl ?? book.coverUrl,
            width: 192, height: 258))),
        const SizedBox(height: 18),
        Text(detail?.entry.title ?? book.title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        Wrap(alignment: WrapAlignment.center,
          spacing: 10, runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (detail?.rating != null) ...[
            const Icon(Icons.star_rounded, color: Color(0xFFFFA04E), size: 21),
            Text('${detail!.rating!.toStringAsFixed(1)} / 10',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          ],
          Chip(label: Text(widget.repository.sources[selected]?.name ?? selected)),
        ]),
        if (detail?.publicationStatus != null ||
            detail?.translationStatus != null)
          Padding(padding: const EdgeInsets.only(top: 12),
            child: Wrap(spacing: 8, runSpacing: 6, children: [
              if (detail?.publicationStatus != null)
                Chip(avatar: const Icon(Icons.calendar_month_outlined, size: 16),
                  label: Text('Статус: ${detail!.publicationStatus!}')),
              if (detail?.translationStatus != null)
                Chip(avatar: const Icon(Icons.translate, size: 16),
                  label: Text('Перевод: ${detail!.translationStatus!}')),
            ])),
        _readingAction(),
        const SizedBox(height: 14),
        AnimatedBuilder(
          animation: widget.library,
          builder: (context, _) {
            final saved = widget.library.get(book);
            final status = saved?.status ?? 'viewed';
            final label = switch (status) {
              'reading' => 'Читаю',
              'planned' => 'В планах',
              'completed' => 'Прочитано',
              'dropped' => 'Заброшено',
              _ => 'Добавить в список',
            };
            return Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              PopupMenuButton<String>(
                tooltip: 'Статус произведения',
                onSelected: (value) async {
                  if (value == 'remove') {
                    await widget.library.remove(book);
                    return;
                  }
                  final wasSaved = widget.library.has(book);
                  await widget.library.setStatus(book, value, preferredSource: selected);
                  if (!wasSaved && context.mounted) await offerChapterAlerts(context, alerts);
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'reading', child: Text('Читаю')),
                  const PopupMenuItem(value: 'planned', child: Text('В планах')),
                  const PopupMenuItem(value: 'completed', child: Text('Прочитано')),
                  const PopupMenuItem(value: 'dropped', child: Text('Заброшено')),
                  const PopupMenuItem(value: 'viewed', child: Text('Открыто')),
                  if (widget.library.has(book))
                    const PopupMenuItem(value: 'remove',
                      child: Text('Убрать из библиотеки')),
                ],
                child: Chip(
                  avatar: const Icon(Icons.bookmark_added_outlined, size: 18),
                  label: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(label),
                    const SizedBox(width: 5),
                    const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
                  ]),
                ),
              ),
              ActionChip(
                avatar: Icon(saved?.favorite == true
                    ? Icons.favorite : Icons.favorite_border, size: 18),
                label: Text(saved?.favorite == true ? 'Любимое ♥' : 'В любимое'),
                onPressed: () => widget.library.setFavorite(book,
                  saved?.favorite != true, preferredSource: selected),
              ),
              Text(saved == null ? 'Нажми, чтобы добавить в библиотеку' :
                  status == 'viewed' ? 'Недавно открыто' : 'В библиотеке',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11)),
            ]);
          },
        ),
        if (detail != null)
          Card(
            margin: const EdgeInsets.only(top: 12, bottom: 12),
            child: Padding(padding: const EdgeInsets.all(13),
              child: Row(children: [
                Expanded(child: Column(children: [
                  const Icon(Icons.library_books_outlined),
                  Text('${detail!.chapters.length} глав',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                ])),
                Expanded(child: Column(children: [
                  const Icon(Icons.menu_book_outlined),
                  Text(widget.repository.sources[selected]?.name ?? selected,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                ])),
              ])),
          ),
        const SizedBox(height: 18),
        if (loading) const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())),
        if (error != null) ...[
          if (!widget.repository.sources.containsKey(selected))
            const Text('Старый источник недоступен. Закладки и история '
                'сохранены; подходящие варианты ищутся автоматически.')
          else
            const Text('Главы временно недоступны. Попробуйте открыть их позже.'),
        ],
        if (detail != null) ...[
          SizedBox(width: double.infinity, child: SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('О тайтле')),
              ButtonSegment(value: true, label: Text('Главы')),
            ],
            selected: {showChapters},
            onSelectionChanged: (value) => setState(() => showChapters = value.first),
          )),
          const SizedBox(height: 8),
          if (!showChapters) ...[
            if (detail!.genres.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(spacing: 6, runSpacing: 4,
                children: detail!.genres.toSet().map((tag) =>
                  Chip(label: Text(tag, style: const TextStyle(fontSize: 11)))).toList()),
            ],
            if (detail!.description.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text(detail!.description,
                maxLines: _descriptionExpanded ? null : 5,
                overflow: _descriptionExpanded ? null : TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.45)),
              if (detail!.description.length > 240)
                TextButton(
                  onPressed: () => setState(() =>
                    _descriptionExpanded = !_descriptionExpanded),
                  child: Text(_descriptionExpanded ? 'Свернуть' : 'Раскрыть полностью')),
            ],
            if (distinctAlternativeNames(detail!.entry.title,
                detail!.alternativeNames).isNotEmpty) ...[
              const SizedBox(height: 18),
              const Text('Альтернативные названия', style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(distinctAlternativeNames(detail!.entry.title,
                detail!.alternativeNames).join(' / '),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
            _similarSection(detail!),
            if (detail!.creators.isNotEmpty) ...[
              const SizedBox(height: 18),
              const Text('Персонал', style: TextStyle(fontSize: 18,
                fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              for (final creator in detail!.creators)
                Padding(padding: const EdgeInsets.only(bottom: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.person_outline, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(creator.name,
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                          if (creator.roles.isNotEmpty)
                            Text(creator.roles.map(_creditRole).join(', '),
                              style: TextStyle(fontSize: 12,
                                color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        ],
                      )),
                    ])),
            ],
          ],
          if (showChapters) ...[
          const SizedBox(height: 24),
          SectionTitle('Главы', subtitle: '${detail!.chapters.length} · ${widget.repository.sources[selected]?.name}'),
          const SizedBox(height: 12),
          if (detail!.chapters.isEmpty)
            Text('Глав нет или они недоступны. Попробуй другой источник.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          Align(alignment: Alignment.centerRight, child: IconButton(
            tooltip: newestFirst ? 'Сначала старые' : 'Сначала новые',
            onPressed: () => setState(() => newestFirst = !newestFirst),
            icon: const Icon(Icons.swap_vert_rounded),
          )),

          ],
        ],
      ];
    return Scaffold(
      appBar: AppBar(title: const Text('')),

      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: staticContent.length +
            (showChapters ? chapterResults.length : 0),
        itemBuilder: (context, index) {
          if (index < staticContent.length) return staticContent[index];
          final chapterIndex = index - staticContent.length;
          final chapter = chapterResults[
              newestFirst ? chapterIndex : chapterResults.length - 1 - chapterIndex];
          return _chapterTile(chapter);
        },
      ),
    );
  }
}
