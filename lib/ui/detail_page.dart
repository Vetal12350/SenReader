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
  bool showChapters = true;
  bool _descriptionExpanded = false;
  String _chapterQuery = '';
  bool newestFirst = true;
  final Set<String> _attempted = {};
  final List<String> _warnings = [];
  int _request = 0;
  bool _explicitSelection = false;
  late final ChapterAlertController alerts = widget.alerts ?? ChapterAlertController();
  @override void initState() {
    super.initState();
    final saved = widget.library.get(widget.book);
    book = UnifiedManga(title: saved?.title ?? widget.book.title,
      entries: {...widget.book.entries, ...?saved?.entries});
    selected = saved?.preferredSource ?? SavedBook.chooseSource(book.entries);
    _load();
    _discoverOther();
  }

  Future<void> _discoverOther() async {
    try {
      final next = await widget.repository.findOtherSources(book);
      if (!mounted) return;
      setState(() => book = next);
      if (widget.library.has(next)) await widget.library.add(next);
      if (mounted && !loading && (detail?.chapters.isEmpty == true || error != null)) {
        _fallback();
      }
    } catch (_) {
      // Optional source discovery must not break the detail screen.
    }
  }

  Future<void> _load() async {
    final request = ++_request;
    final sourceKey = selected;
    _attempted.add(sourceKey);
    setState(() { loading = true; error = null; detail = null; _similarFuture = null; _chapterQuery = ''; });
    try {
      final source = widget.repository.sources[sourceKey];
      if (source == null) throw StateError('Источник $sourceKey недоступен');
      final next = await source.detail(book.entries[sourceKey]!);
      if (!mounted || request != _request) return;
      setState(() { loading = false; detail = next; });
      if (next.chapters.isEmpty) {
        _warnings.add('${source.name}: публичные главы недоступны.');
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
    if (widget.library.has(book) || _explicitSelection) return;
    for (final source in book.entries.keys) {
      if (!_attempted.contains(source) && widget.repository.sources.containsKey(source)) {
        setState(() => selected = source);
        _load();
        return;
      }
    }
  }

  Future<void> _select(String value) async {
    if (selected == value) return;
    setState(() {
      selected = value;
      _explicitSelection = true;
      _attempted.clear();
      _warnings.clear();
    });
    final pending = _load();
    await widget.library.setPreferredSource(book, value);
    await pending;
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
                        unawaited(widget.library.markViewed(recommendation));
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

  void _retry() {
    _attempted.clear();
    _warnings.clear();
    _load();
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
      return Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 8),
        child: SizedBox(width: double.infinity, child: FilledButton.icon(
          key: const Key('title-read-button'),
          onPressed: target == null ? null : () => _openChapter(target!),
          icon: const Icon(Icons.menu_book_rounded),
          label: Text(saved?.lastChapter.isNotEmpty == true && target != null
            ? 'Продолжить ${RegExp(r'[0-9]+(?:[.,][0-9]+)?').firstMatch(target.name)?.group(0) ?? target.name} главу'
            : 'Читать'),
        )),
      );
    },
  );

  static String _creditRole(String role) => switch (role.toUpperCase()) {
    'AUTHOR' || 'WRITER' || 'STORY' => 'Сюжет',
    'ARTIST' || 'ILLUSTRATOR' || 'ART' => 'Иллюстрации',
    _ => role,
  };

  @override Widget build(BuildContext context) {
    final chapterResults = (detail?.chapters ?? const <Chapter>[])
        .where((chapter) => chapter.name.toLowerCase().contains(
          _chapterQuery.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: const Text(''), actions: [
        PopupMenuButton<String>(
          tooltip: 'Сменить источник', icon: const Icon(Icons.source_outlined),
          initialValue: selected, onSelected: _select,
          itemBuilder: (context) => [for (final source in book.entries.keys)
            CheckedPopupMenuItem(value: source, checked: selected == source,
              child: Text(widget.repository.sources[source]?.name ?? source))],
        ),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
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
        _readingAction(),
        const SizedBox(height: 14),
        AnimatedBuilder(
          animation: widget.library,
          builder: (context, _) {
            final saved = widget.library.get(book);
            final status = saved?.status ?? 'viewed';
            const label = 'Добавить в список';
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
        // A failed alternative source is not an error when another source works.
        if (!loading && detail == null)
          for (final warning in _warnings.take(2))
            Text(warning, style: const TextStyle(color: Color(0xFFFFBE80))),
        if (loading) const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())),
        if (error != null) ...[
          Text('Не удалось получить главы: $error', style: const TextStyle(color: Color(0xFFFFBE80))),
          const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: _retry, icon: const Icon(Icons.refresh), label: const Text('Повторить')),
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
          TextField(
            key: const Key('chapter-search'),
            onChanged: (value) => setState(() => _chapterQuery = value),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Номер или название главы'),
          ),
          if (detail!.chapters.isEmpty)
            Text('Глав нет или они недоступны. Попробуй другой источник.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          Align(alignment: Alignment.centerRight, child: IconButton(
            tooltip: newestFirst ? 'Сначала старые' : 'Сначала новые',
            onPressed: () => setState(() => newestFirst = !newestFirst),
            icon: const Icon(Icons.swap_vert_rounded),
          )),
          for (var index = 0; index < chapterResults.length; index++) ...[
            if (index == 0 || chapterVolume(
                  chapterResults[newestFirst ? index : chapterResults.length - 1 - index])
                != chapterVolume(chapterResults[
                  newestFirst ? index - 1 : chapterResults.length - index]))
              Align(alignment: Alignment.centerLeft, child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(chapterVolume(
                  chapterResults[newestFirst ? index : chapterResults.length - 1 - index]),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              )),
            Builder(builder: (context) {
              final chapter = chapterResults[
                newestFirst ? index : chapterResults.length - 1 - index];
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
                            availableChapters: detail!.chapters);
                        }
                      },
                    ),
                    title: Text(chapter.name,
                      style: TextStyle(color: read ? Theme.of(context).colorScheme.onSurfaceVariant : null)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openChapter(chapter),
                  );
                },
              );
            }),
          ],
          ],
        ],
      ]),
    );
  }
}
