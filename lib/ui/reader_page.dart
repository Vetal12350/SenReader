import 'package:flutter/material.dart';
import '../core/models.dart';
import '../data/catalog_repository.dart';
import '../data/library_store.dart';

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.book, required this.chapter,
    required this.sourceKey, required this.repository, required this.library});
  final UnifiedManga book;
  final Chapter chapter;
  final String sourceKey;
  final CatalogRepository repository;
  final LibraryStore library;
  @override State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late final Future<List<PageImage>> future;
  @override void initState() {
    super.initState();
    future = widget.repository.sources[widget.sourceKey]!.pages(widget.chapter);
  }

  @override Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.chapter.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [IconButton(tooltip: 'Отметить прочитанной', icon: const Icon(Icons.check_circle_outline), onPressed: _mark)]),
      backgroundColor: Colors.black,
      body: FutureBuilder<List<PageImage>>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Ошибка главы: ${snapshot.error}')));
          }
          final pages = snapshot.data ?? [];
          if (pages.isEmpty) {
            return const Center(child: Padding(padding: EdgeInsets.all(24),
              child: Text('Нет доступных изображений. Возможно, глава удалена или доступ ограничен.')));
          }
          return ListView.builder(
            itemCount: pages.length + 1,
            itemBuilder: (context, index) {
              if (index == pages.length) {
                return Padding(padding: const EdgeInsets.all(24),
                  child: FilledButton.icon(onPressed: _mark,
                    icon: const Icon(Icons.check), label: const Text('Глава прочитана')));
              }
              return Image.network(
                pages[index].url,
                headers: pages[index].headers,
                fit: BoxFit.fitWidth,
                frameBuilder: (context, child, frame, wasSync) => frame == null
                  ? const SizedBox(height: 170, child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
                  : child,
                errorBuilder: (context, error, stack) => Container(
                  height: 170, color: Colors.white10, alignment: Alignment.center,
                  child: Text('Страница ${index + 1} не загрузилась', style: const TextStyle(color: Colors.white60))),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _mark() async {
    await widget.library.markRead(widget.book, widget.chapter, widget.sourceKey);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Прогресс чтения сохранён')));
  }
}
