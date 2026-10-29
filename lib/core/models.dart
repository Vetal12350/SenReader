class MangaEntry {
  const MangaEntry({required this.source, required this.id, required this.title, this.coverUrl = ''});
  final String source;
  final String id;
  final String title;
  final String coverUrl;

  Map<String, dynamic> toJson() => {
        'source': source, 'id': id, 'title': title, 'coverUrl': coverUrl,
      };

  factory MangaEntry.fromJson(Map<String, dynamic> json) => MangaEntry(
        source: json['source'] as String? ?? '',
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        coverUrl: json['coverUrl'] as String? ?? '',
      );
}

class Chapter {
  const Chapter({required this.id, required this.name, this.volume,
    this.number, this.readable = true});
  final String id;
  final String name;
  final String? volume;
  final String? number;
  final bool readable;

  Map<String, dynamic> toJson() => {'id': id, 'name': name,
    'volume': volume, 'number': number, 'readable': readable};
  factory Chapter.fromJson(Map<String, dynamic> json) => Chapter(
    id: json['id'] as String, name: json['name'] as String,
    volume: json['volume'] as String?, number: json['number'] as String?,
    readable: json['readable'] != false);
}

class PageImage {
  const PageImage(this.url, {this.headers = const {}});
  final String url;
  final Map<String, String> headers;
}

class MangaDetail {
  const MangaDetail({required this.entry, required this.chapters, this.description = '', this.genres = const []});
  final MangaEntry entry;
  final List<Chapter> chapters;
  final String description;
  final List<String> genres;
}

class UnifiedManga {
  UnifiedManga({required this.title, required this.entries, this.savedId,
    this.requiresLinkApproval = false});
  final String title;
  final Map<String, MangaEntry> entries;
  final String? savedId;
  final bool requiresLinkApproval;
  MangaEntry get primary => entries['senkuro'] ?? entries.values.first;
  String get coverUrl => primary.coverUrl.isNotEmpty
      ? primary.coverUrl
      : entries.values.firstWhere((e) => e.coverUrl.isNotEmpty, orElse: () => primary).coverUrl;
}

class CatalogResult {
  const CatalogResult({required this.books, required this.warnings});
  final List<UnifiedManga> books;
  final List<String> warnings;
}
