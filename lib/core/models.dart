class MangaEntry {
  const MangaEntry({required this.source, required this.id, required this.title,
    this.coverUrl = '', this.tags = const [], this.rating, this.remoteId = ''});
  final String source;
  final String id;
  final String remoteId; // Source's stable API ID if different from slug.
  final String title;
  final String coverUrl;
  final List<String> tags; // Public source labels, empty when not provided.
  final double? rating; // Verified 0–10 source rating; null if unavailable.

  Map<String, dynamic> toJson() => {
        'source': source, 'id': id, 'title': title, 'coverUrl': coverUrl,
        if (tags.isNotEmpty) 'tags': tags,
        if (rating != null) 'rating': rating,
        if (remoteId.isNotEmpty) 'remoteId': remoteId,
      };

  factory MangaEntry.fromJson(Map<String, dynamic> json) => MangaEntry(
        source: json['source'] as String? ?? '',
        id: json['id'] as String? ?? '',
        remoteId: json['remoteId'] as String? ?? '',
        title: json['title'] as String? ?? '',
        coverUrl: json['coverUrl'] as String? ?? '',
        rating: tenPointScore(json['rating']),
        tags: (json['tags'] is List ? (json['tags'] as List) : const [])
            .whereType<String>().where((s) => s.isNotEmpty && s.length <= 80)
            .take(32).toList(),
      );
}

class Chapter {
  const Chapter({required this.id, required this.name, this.publishedAt});
  final String id;
  final String name;
  /// Actual source-provided upload date; null means unknown.
  final DateTime? publishedAt;
}

/// Parse only a timestamp returned by a reader source; never invent dates.
DateTime? sourceChapterDate(Object? raw) {
  if (raw == null) return null;
  DateTime? date;
  if (raw is num) {
    final millis = raw > 100000000000 ? raw.toInt()
        : raw > 1000000000 ? (raw * 1000).toInt() : 0;
    if (millis > 0) {
      date = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    }
  } else if (raw is String && raw.trim().isNotEmpty) {
    final value = raw.trim();
    final numeric = int.tryParse(value);
    if (numeric != null) return sourceChapterDate(numeric);
    date = DateTime.tryParse(value);
  }
  if (date == null || date.year < 2000 ||
      date.isAfter(DateTime.now().add(const Duration(days: 2)))) {
    return null;
  }
  return date;
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
    this.alternativeNames = const [], this.creators = const [],
    this.publicationStatus, this.translationStatus, this.chaptersComplete = true});
  final MangaEntry entry;
  final List<Chapter> chapters;
  final bool chaptersComplete;
  final String description;
  final String? publicationStatus;
  final String? translationStatus;
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
