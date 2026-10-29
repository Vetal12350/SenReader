import 'models.dart';

// Use decimal strings: double conversion would lose precision for long fractions.
String? canonicalDecimal(String? value) {
  if (value == null) return null;
  final text = value.trim().replaceAll(',', '.');
  if (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(text)) return null;
  final parts = text.split('.');
  final whole = parts.first.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  final fraction = parts.length == 1 ? '' : parts[1].replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? whole : '$whole.$fraction';
}

({String? volume, String? number}) chapterCoordinates(String name) {
  final pair = RegExp(r'^(\d+)\s*[-—]\s*(\d+(?:[.,]\d+)?)(?=\s|:|$)').firstMatch(name.trim());
  if (pair != null) return (volume: pair[1], number: pair[2]);
  final labeled = RegExp(
    r'^(?:(?:том|vol(?:ume)?\.?)\s*(\d+)\s*[,.:—-]?\s*)?(?:глава|chapter|ch\.?)\s*(\d+(?:[.,]\d+)?)(?=\s|:|$)',
    caseSensitive: false).firstMatch(name.trim());
  return (volume: labeled?[1], number: labeled?[2]);
}

String? canonicalChapterKey(Chapter chapter) {
  final parsed = chapterCoordinates(chapter.name);
  final number = canonicalDecimal(chapter.number ?? parsed.number);
  // Sources without volume metadata share the documented volume 0 namespace.
  final volume = canonicalDecimal(chapter.volume ?? parsed.volume ?? '0');
  if (number == null || volume == null) return null;
  return 'v$volume:c$number';
}

class ChapterRelease {
  const ChapterRelease({required this.source, required this.chapter, this.detectedAtMicros});
  final String source;
  final Chapter chapter;
  final int? detectedAtMicros;
  String get key => canonicalChapterKey(chapter)!;
  Map<String, dynamic> toJson() => {'source': source, 'chapter': chapter.toJson(),
    'detectedAtMicros': detectedAtMicros};
  factory ChapterRelease.fromJson(Map<String, dynamic> json) => ChapterRelease(
    source: json['source'] as String, detectedAtMicros: json['detectedAtMicros'] as int?,
    chapter: Chapter.fromJson(Map<String, dynamic>.from(json['chapter'] as Map)));
}

class ChapterUpdateState {
  ChapterUpdateState({this.initialized = false, Set<String>? seen,
    Set<String>? notified, Map<String, ChapterRelease>? inbox})
      : seen = Set.unmodifiable(seen ?? <String>{}),
        notified = Set.unmodifiable(notified ?? <String>{}),
        inbox = Map.unmodifiable(inbox ?? <String, ChapterRelease>{});
  final bool initialized;
  final Set<String> seen;
  final Set<String> notified;
  // A durable manual-check inbox survives interruption between saving and display.
  final Map<String, ChapterRelease> inbox;

  Map<String, dynamic> toJson() => {'initialized': initialized,
    'seen': seen.toList(), 'notified': notified.toList(),
    'inbox': inbox.map((k, v) => MapEntry(k, v.toJson()))};
  factory ChapterUpdateState.fromJson(Map<String, dynamic> json) => ChapterUpdateState(
    initialized: json['initialized'] == true,
    seen: (json['seen'] as List? ?? []).cast<String>().toSet(),
    notified: (json['notified'] as List? ?? []).cast<String>().toSet(),
    inbox: (json['inbox'] as Map? ?? {}).map((k, v) => MapEntry(k as String,
      ChapterRelease.fromJson(Map<String, dynamic>.from(v as Map)))));
}

class ChapterCheckResult {
  const ChapterCheckResult({required this.state, required this.newChapters,
    required this.available, required this.successfulSources, this.warnings = const []});
  final ChapterUpdateState state;
  final List<ChapterRelease> newChapters;
  final Map<String, List<ChapterRelease>> available;
  final int successfulSources;
  final List<String> warnings;
}

/// Pure reduction. Input order is accessibility detection order, never provider
/// priority or an assertion about publication time. Failed lookups supply no data.
ChapterCheckResult reduceChapterCheck(ChapterUpdateState previous,
    Iterable<ChapterRelease> detected, {required int successfulSources,
    List<String> warnings = const []}) {
  final seen = {...previous.seen};
  final notified = {...previous.notified};
  final inbox = {...previous.inbox};
  final added = <ChapterRelease>[];
  final available = <String, List<ChapterRelease>>{};
  for (final release in detected) {
    final key = canonicalChapterKey(release.chapter);
    if (!release.chapter.readable || key == null) continue;
    available.putIfAbsent(key, () => []).add(release);
    if (!seen.add(key)) continue;
    if (previous.initialized && notified.add(key)) {
      added.add(release);
      inbox.putIfAbsent(key, () => release);
    }
  }
  return ChapterCheckResult(
    state: ChapterUpdateState(
      initialized: previous.initialized || successfulSources > 0,
      seen: seen, notified: notified, inbox: inbox),
    newChapters: added, available: available,
    successfulSources: successfulSources, warnings: warnings);
}
