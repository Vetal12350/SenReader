import 'package:flutter/material.dart';
import '../core/models.dart';

class CoverImage extends StatelessWidget {
  const CoverImage(this.url, {super.key, this.width, this.height, this.headers = const {}});
  final String url;
  final double? width;
  final double? height;
  final Map<String, String> headers;

  @override Widget build(BuildContext context) {
    final fallback = Container(width: width, height: height,
      color: const Color(0xFF33313B),
      alignment: Alignment.center,
      child: const Icon(Icons.menu_book_rounded, color: Colors.white38, size: 30));
    if (!url.startsWith('https://')) return fallback;
    return Image.network(url, width: width, height: height, fit: BoxFit.cover,
      headers: headers, errorBuilder: (context, error, stack) => fallback);
  }
}

class MangaTile extends StatelessWidget {
  const MangaTile({super.key, required this.book, required this.onTap,
    this.statusLabel});
  final UnifiedManga book;
  final VoidCallback onTap;
  final String? statusLabel;
  @override Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12), onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(aspectRatio: 0.72, child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(fit: StackFit.expand, children: [
            CoverImage(book.coverUrl),
            if (statusLabel != null)
              Positioned(left: 6, top: 6,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF893F),
                    borderRadius: BorderRadius.circular(7)),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 4),
                  child: Text(statusLabel!,
                    style: const TextStyle(color: Colors.black,
                      fontSize: 10, fontWeight: FontWeight.w700)),
                )),
            Positioned(left: 6, bottom: 6, child: Container(
              decoration: BoxDecoration(color: const Color(0xD916161D), borderRadius: BorderRadius.circular(7)),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(book.entries.length > 1 ? '${book.entries.length} источника' :
                book.primary.source == 'senkuro' ? 'Senkuro' :
                book.primary.source == 'remanga' ? 'ReManga' : 'ReadManga',
                style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700)),
            )),
          ]),
        )),
        const SizedBox(height: 7),
        Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
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
        if (subtitle.isNotEmpty) Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
      Icon(icon, size: 46, color: Colors.white30),
      const SizedBox(height: 12),
      Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60)),
    ]),
  ));
}
