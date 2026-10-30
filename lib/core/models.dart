class MangaEntry {
  const MangaEntry({required this.source, required this.id, required this.title,
    this.coverUrl = '', this.tags = const []});
  final String source;
  final String id;
  final String title;
  final String coverUrl;
  final List<String> tags; // Public source labels, empty when not provided.

  Map<String, dynamic> toJson() => {
        'source': source, 'id': id, 'title': title, 'coverUrl': coverUrl,
        if (tags.isNotEmpty) 'tags': tags,
      };

  factory MangaEntry.fromJson(Map<String, dynamic> json) => MangaEntry(
        source: json['source'] as String? ?? '',
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        coverUrl: json['coverUrl'] as String? ?? '',
        tags: (json['tags'] is List ? (json['tags'] as List) : const [])
            .whereType<String>().where((s) => s.isNotEmpty && s.length <= 80)
            .take(32).toList(),
      );
}

class Chapter {
  const Chapter({required this.id, required this.name});
  final String id;
  final String name;
}

class PageImage {
  const PageImage(this.url, {this.headers = const {}});
  final String url;
  final Map<String, String> headers;
}

class MangaCreator {
  const MangaCreator({required this.name, this.roles = const []});
  final String name;
  final List<String> roles;
}

class MangaDetail {
  const MangaDetail({required this.entry, required this.chapters,
    this.description = '', this.genres = const [], this.rating,
    this.alternativeNames = const [], this.creators = const []});
  final MangaEntry entry;
  final List<Chapter> chapters;
  final String description;
  final List<String> genres;
  /// Verified source rating converted to a 0–10 scale. Null = unknown.
  final double? rating;
  final List<String> alternativeNames;
  /// Verified creator credits supplied by the selected source, if present.
  final List<MangaCreator> creators;
}

class UnifiedManga {
  UnifiedManga({required this.title, required this.entries});
  final String title;
  final Map<String, MangaEntry> entries;
  MangaEntry get primary => entries['senkuro'] ?? entries.values.first;
  String get coverUrl => primary.coverUrl.isNotEmpty
      ? primary.coverUrl
      : entries.values.firstWhere((e) => e.coverUrl.isNotEmpty, orElse: () => primary).coverUrl;
}

class CatalogResult {
  const CatalogResult({required this.books, required this.warnings,
    this.senkuroPopular = const []});
  final List<UnifiedManga> books;
  final List<String> warnings;
  /// Senkuro's public POPULARITY_SCORE order, not a verified daily chart.
  final List<MangaEntry> senkuroPopular;
}


/// Public aggregate score only. No age ratings, popularity ranking or votes
/// are converted into a fictitious reader score.
double? tenPointScore(dynamic raw, {double max = 10}) {
  if (raw is! num && raw is! String) return null;
  final score = raw is num ? raw.toDouble() : double.tryParse(raw);
  if (score == null || !score.isFinite || max <= 0 || max > 100 ||
      score <= 0 || score > max) return null;
  final normalized = score * 10 / max;
  return double.parse(normalized.toStringAsFixed(1));
}
