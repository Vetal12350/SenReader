import 'dart:ui';
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
  bool showChapters = true;
  bool newestFirst = true;
  final Set<String> _attempted = {};
  final List<String> _warnings = [];
  int _request = 0;
  @override void initState() {
    super.initState();
    book = widget.book;
    selected = book.primary.source;
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
    for (final source in book.entries.keys) {
      if (!_attempted.contains(source) && widget.repository.sources.containsKey(source)) {
        setState(() => selected = source);
        _load();
        return;
      }
    }
  }

  void _select(String value) {
    if (selected == value) return;
    setState(() {
      selected = value;
      _attempted.clear();
      _warnings.clear();
    });
    _load();
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
        if (chapter.name == previous.lastChapter) {
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
                    fontWeight: FontWeight.w800)),
                if (detail?.alternativeNames.isNotEmpty == true) ...[
                  const SizedBox(height: 8),
                  Text(detail!.alternativeNames.take(3).join(' / '),
                    maxLines: 3, textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70)),
                ],
                if (detail?.rating != null) ...[
                  const SizedBox(height: 11),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.star_rounded,
                      color: Color(0xFFFFD37E), size: 21),
                    const SizedBox(width: 4),
                    Text(detail!.rating!.toStringAsFixed(1) + ' / 10',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(width: 7),
                    Text(widget.repository.sources[selected]?.name ?? selected,
                      style: const TextStyle(color: Colors.white70)),
                  ]),
                ],
              ]),
            ),
          ])),
        const SizedBox(height: 14),
        const Text('Источник глав',
          style: TextStyle(color: Colors.white70, fontSize: 12)),
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
          if (!showChapters && detail!.genres.isNotEmpty)
            Wrap(spacing: 6, runSpacing: 4, children: detail!.genres.map((g) => Chip(label: Text(g, style: const TextStyle(fontSize: 11)))).toList()),
          if (!showChapters && detail!.alternativeNames.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(detail!.alternativeNames.join(' / '),
              maxLines: 3, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white60)),
          ],
          if (!showChapters && detail!.description.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(detail!.description, maxLines: 7, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, height: 1.45)),
          ],
          if (showChapters) ...[
          const SizedBox(height: 24),
          SectionTitle('Главы', subtitle: '${detail!.chapters.length} · ${widget.repository.sources[selected]?.name}'),
          if (detail!.chapters.isEmpty)
            const Text('Глав нет или они недоступны. Попробуй другой источник.', style: TextStyle(color: Colors.white60)),
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
                    leading: Icon(read ? Icons.check_circle_rounded :
                        Icons.menu_book_outlined,
                      color: read ? Theme.of(context).colorScheme.primary : null),
                    title: Text(chapter.name,
                      style: TextStyle(color: read ? Colors.white60 : null)),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: read ? 'Снять отметку о прочтении' : 'Отметить прочитанной',
                        icon: Icon(read ? Icons.bookmark_added_rounded :
                            Icons.bookmark_add_outlined),
                        onPressed: () async {
                          if (read) {
                            await widget.library.unmarkRead(book, chapter, selected);
                          } else {
                            await widget.library.markRead(book, chapter, selected);
                          }
                        },
                      ),
                      const Icon(Icons.chevron_right),
                    ]),
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
