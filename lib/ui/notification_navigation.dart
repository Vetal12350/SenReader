import 'package:flutter/material.dart';
import '../core/models.dart';
import '../data/catalog_repository.dart';
import '../data/chapter_alert_controller.dart';
import '../data/library_store.dart';
import 'detail_page.dart';
import 'reader_page.dart';

SavedBook? notificationBook(LibraryStore library, Map<String, String> fields) {
  if (library.profileId != (fields['profile'] ?? '')) return null;
  final source = fields['source'];
  for (final book in library.items) {
    final entry = book.entries[source];
    if (entry == null) continue;
    if (fields['titleId'] != null ? entry.id == fields['titleId'] : book.key == fields['book']) {
      return book;
    }
  }
  return null;
}

Chapter? notificationChapter(Iterable<Chapter> chapters, String id) =>
    chapters.where((chapter) => chapter.id == id).firstOrNull;

Future<void> openChapterNotification(BuildContext context,
    {required Map<String, String> fields, required LibraryStore library,
     required CatalogRepository repository, ChapterAlertController? alerts}) async {
  void error(String message) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
  await library.load();
  final saved = notificationBook(library, fields);
  if (!context.mounted) return;
  if (saved == null) { error('Произведение из уведомления недоступно'); return; }
  if (fields['action'] != 'chapter') {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => DetailPage(
      book: saved.toUnified(), repository: repository, library: library, alerts: alerts)));
    return;
  }
  final sourceKey = fields['source']!;
  final source = repository.sources[sourceKey];
  if (source == null) { error('Источник главы недоступен'); return; }
  final titleId = saved.entries[sourceKey]!.id;
  try {
    final detail = await source.detail(saved.entries[sourceKey]!);
    await library.load();
    if (!context.mounted) return;
    final current = notificationBook(library, fields);
    if (current == null || current.entries[sourceKey]?.id != titleId) {
      error('Произведение из уведомления недоступно'); return;
    }
    final chapter = notificationChapter(detail.chapters, fields['chapter']!);
    if (chapter == null) { error('Глава больше недоступна'); return; }
    if (current.preferredSource != sourceKey) {
      await library.setPreferredSource(current.toUnified(), sourceKey,
        expectedProfile: fields['profile'] ?? '');
      if (!context.mounted || library.profileId != (fields['profile'] ?? '')) return;
    }
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ReaderPage(
      book: current.toUnified(), chapter: chapter, sourceKey: sourceKey,
      repository: repository, library: library, chapters: detail.chapters)));
    // Reader's successful page-list load persists the selected notification's
    // read status through LibraryStore.markRead. Failed/empty loads keep it new.
  } catch (_) { error('Не удалось открыть главу'); }
}
