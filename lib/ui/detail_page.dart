import 'dart:ui';
import 'package:flutter/material.dart';
import '../core/models.dart';
import '../data/catalog_repository.dart';
import '../data/library_store.dart';
import '../core/title_metadata.dart';
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
  bool loading = true;
  String? error;
  bool showChapters = true;
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
    setState(() { loading = true; error = null; detail = null; });
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

  Widget _continueAction() => AnimatedBuilder(
    animation: widget.library,
    builder: (context, _) {
      final previous = widget.library.get(book);
      if (previous == null || previous.lastSource != selected ||
          previous.lastChapter.isEmpty || detail == null) {
        return const SizedBox.shrink();
      }
      Chapter? match;
      for (final chapter in detail!.chapters) {
        if (previous.lastChapterId.isNotEmpty
            ? chapter.id == previous.lastChapterId
            : chapter.name == previous.lastChapter) {
          match = chapter;
          break;
        }
      }
      if (match == null) return const SizedBox.shrink();
      final target = match;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: SizedBox(width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => _openChapter(target),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text('Продолжить: ' + target.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      );
    },
  );

  @override Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Произведение', maxLines: 1,
        overflow: TextOverflow.ellipsis), actions: [
        PopupMenuButton<String>(
          tooltip: 'Сменить источник', icon: const Icon(Icons.source_outlined),
          initialValue: selected, onSelected: _select,
          itemBuilder: (context) => [for (final source in book.entries.keys)
            CheckedPopupMenuItem(value: source, checked: selected == source,
              child: Text(widget.repository.sources[source]?.name ?? source))],
        ),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        ClipRRect(borderRadius: BorderRadius.circular(16),
          child: Stack(children: [
            Positioned.fill(child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
              child: CoverImage(detail?.entry.coverUrl ?? book.coverUrl,
                width: double.infinity, height: 360))),
            Container(width: double.infinity,
              padding: const EdgeInsets.fromLTRB(14, 20, 14, 20),
              decoration: const BoxDecoration(gradient: LinearGradient(
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: [Color(0x9917131B), Color(0xE519131E)])),
              child: Column(children: [
                ClipRRect(borderRadius: BorderRadius.circular(12),
                  child: CoverImage(detail?.entry.coverUrl ?? book.coverUrl,
                    width: 148, height: 204)),
                const SizedBox(height: 16),
                Text(detail?.entry.title ?? book.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 24,
                    color: Colors.white, fontWeight: FontWeight.w800)),
                if (detail?.rating != null) ...[
                  const SizedBox(height: 11),
                  Wrap(alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center, children: [
                    const Icon(Icons.star_rounded,
                      color: Color(0xFFFFD37E), size: 21),
                    const SizedBox(width: 4),
                    Text(detail!.rating!.toStringAsFixed(1) + ' / 10',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(width: 7),
                    Text(widget.repository.sources[selected]?.name ?? selected,
                      style: const TextStyle(color: Colors.white70)),
                  ]),
                ],
              ]),
            ),
          ])),
        const SizedBox(height: 14),
        AnimatedBuilder(
          animation: widget.library,
          builder: (context, _) {
            final saved = widget.library.get(book);
            final status = saved?.status ?? 'viewed';
            final label = status == 'reading' ? 'Читаю' :
                status == 'completed' ? 'Прочитано' :
                status == 'planned' ? 'В планах' :
                status == 'dropped' ? 'Заброшено' :
                saved == null ? 'Не в списках' : 'Открыто';
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
        _continueAction(),
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
              ButtonSegment(value: false, label: Text('Информация')),
              ButtonSegment(value: true, label: Text('Главы')),
            ],
            selected: {showChapters},
            onSelectionChanged: (value) => setState(() => showChapters = value.first),
          )),
          const SizedBox(height: 8),
          if (!showChapters) ...[
            if (detail!.description.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Text('Описание', style: TextStyle(fontSize: 18,
                fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(detail!.description,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.45)),
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
            if (detail!.genres.isNotEmpty) ...[
              const SizedBox(height: 18),
              const Text('Жанры и теги', style: TextStyle(fontSize: 18,
                fontWeight: FontWeight.bold)),
              Wrap(spacing: 6, runSpacing: 4,
                children: detail!.genres.toSet().map((g) => Chip(
                  label: Text(g, style: const TextStyle(fontSize: 11)))).toList()),
            ],
            if (detail!.creators.isNotEmpty) ...[
              const SizedBox(height: 18),
              const Text('Создатели', style: TextStyle(fontSize: 18,
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
                            Text(creator.roles.join(', '),
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
          if (detail!.chapters.isEmpty)
            Text('Глав нет или они недоступны. Попробуй другой источник.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          Align(alignment: Alignment.centerRight, child: IconButton(
            tooltip: newestFirst ? 'Сначала старые' : 'Сначала новые',
            onPressed: () => setState(() => newestFirst = !newestFirst),
            icon: const Icon(Icons.swap_vert_rounded),
          )),
          for (var index = 0; index < detail!.chapters.length; index++) ...[
            if (index == 0 || chapterVolume(
                  detail!.chapters[newestFirst ? index : detail!.chapters.length - 1 - index])
                != chapterVolume(detail!.chapters[
                  newestFirst ? index - 1 : detail!.chapters.length - index]))
              Align(alignment: Alignment.centerLeft, child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(chapterVolume(
                  detail!.chapters[newestFirst ? index : detail!.chapters.length - 1 - index]),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              )),
            Builder(builder: (context) {
              final chapter = detail!.chapters[
                newestFirst ? index : detail!.chapters.length - 1 - index];
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
