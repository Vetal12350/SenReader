import 'package:flutter/material.dart';
import '../core/models.dart';
import '../data/library_store.dart';

/// Saved reading-list status and last reached chapter; never show a badge
/// for titles merely opened while browsing.
String? readingStatusBadge(SavedBook? saved) {
  if (saved == null || saved.status == 'viewed') return null;
  final label = switch (saved.status) {
    'reading' => 'Читаю',
    'planned' => 'В планах',
    'completed' => 'Прочитано',
    'dropped' => 'Заброшено',
    _ => null,
  };
  if (label == null) return null;
  final chapterName = saved.lastMarkedChapter.isNotEmpty
      ? saved.lastMarkedChapter
      : saved.lastSource == saved.preferredSource ? saved.lastChapter : '';
  final chapter = RegExp(
    r'(?:глава|chapter|ch\.?)\s*([0-9]+(?:[.,][0-9]+)?)',
    caseSensitive: false,
  ).firstMatch(chapterName)?.group(1);
  return chapter == null ? label : '$label · $chapter гл.';
}

class CoverImage extends StatelessWidget {
  const CoverImage(this.url, {super.key, this.width, this.height, this.headers = const {}});
  final String url;
  final double? width;
  final double? height;
  final Map<String, String> headers;

  @override Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final fallback = Container(width: width, height: height,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(Icons.menu_book_rounded,
          color: Theme.of(context).colorScheme.onSurfaceVariant, size: 30));
      if (!url.startsWith('https://')) return fallback;
      // Decode only the resolution required for a thumbnail or title cover.
      // Keep a few shared buckets so the same image can reuse Flutter's cache.
      final logicalWidth = width ?? (constraints.hasBoundedWidth
          ? constraints.maxWidth : MediaQuery.sizeOf(context).width);
      final physicalWidth =
          (logicalWidth * MediaQuery.devicePixelRatioOf(context)).ceil();
      final decodeWidth = physicalWidth <= 256 ? 256 :
          physicalWidth <= 512 ? 512 :
          physicalWidth <= 768 ? 768 : 1024;
      return Image.network(url, width: width, height: height,
        cacheWidth: decodeWidth, fit: BoxFit.cover,
        headers: headers, errorBuilder: (context, error, stack) => fallback);
    });
  }
}

class MangaTile extends StatelessWidget {
  const MangaTile({super.key, required this.book, required this.onTap,
    this.statusLabel, this.saved});
  final UnifiedManga book;
  final VoidCallback onTap;
  final String? statusLabel;
  final SavedBook? saved;
  static const coverAspectRatio = 0.72;
  static const titleStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.w600);

  static double titleHeight(BuildContext context, double width) {
    final painter = TextPainter(
      text: TextSpan(text: 'Аg\nАg',
          style: DefaultTextStyle.of(context).style.merge(titleStyle)),
      maxLines: 2, textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: width);
    final height = painter.height;
    painter.dispose();
    return height;
  }

  static double heightFor(BuildContext context, double width) =>
      width / coverAspectRatio + 7 + titleHeight(context, width);

  @override Widget build(BuildContext context) {
    final badge = statusLabel ?? readingStatusBadge(saved);
    return LayoutBuilder(builder: (context, constraints) => InkWell(
      borderRadius: BorderRadius.circular(12), onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(aspectRatio: coverAspectRatio, child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(fit: StackFit.expand, children: [
            CoverImage(book.coverUrl),
            if (badge != null)
              Positioned(left: 6, right: 6, top: 6,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF893F),
                    borderRadius: BorderRadius.circular(7)),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 4),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(badge, maxLines: 1,
                      style: const TextStyle(color: Colors.black,
                        fontSize: 10, fontWeight: FontWeight.w700)),
                  ),
                )),
            if (book.primary.rating != null)
              Positioned(right: 6, bottom: 6, child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(color: const Color(0xE316161D),
                  borderRadius: BorderRadius.circular(7)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.star_rounded, color: Color(0xFF5BCA72), size: 12),
                  const SizedBox(width: 3),
                  Text(book.primary.rating!.toStringAsFixed(2),
                    style: const TextStyle(fontSize: 10, color: Color(0xFF5BCA72),
                      fontWeight: FontWeight.w700)),
                ]))),
            Positioned(left: 6, bottom: 6, child: Container(
              decoration: BoxDecoration(color: const Color(0xD916161D), borderRadius: BorderRadius.circular(7)),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(
                book.entries.keys.where(
                    (key) => key == 'senkuro' || key == 'readmanga').length > 1
                  ? '2 источника'
                  : book.entries.containsKey('senkuro') ? 'Senkuro'
                  : book.entries.containsKey('readmanga') ? 'Доп. источник'
                  : 'Источник удалён',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white)),
            )),
          ]),
        )),
        const SizedBox(height: 7),
        SizedBox(height: titleHeight(context, constraints.maxWidth),
          child: Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: titleStyle)),
      ]),
    ));
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.subtitle = ''});
  final String title;
  final String subtitle;
  @override Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        if (subtitle.isNotEmpty) Text(subtitle, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
      ]),
  );
}

class EmptyView extends StatelessWidget {
  const EmptyView({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override Widget build(BuildContext context) => Center(child: Padding(
    padding: const EdgeInsets.all(36),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 46, color: Theme.of(context).colorScheme.onSurfaceVariant),
      const SizedBox(height: 12),
      Text(text, textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
    ]),
  ));
}
