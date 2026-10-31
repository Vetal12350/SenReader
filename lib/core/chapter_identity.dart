import 'models.dart';

/// Stable chapter identity shared across providers and translations.
/// Do not key on provider slug, row position, or chapter subtitle.
String? canonicalChapterKey(Chapter chapter) {
  final label = chapter.name.toLowerCase().replaceAll(',', '.');
  final number = RegExp(r'(?:глава|chapter|ch\.?)\s*([0-9]+(?:\.[0-9]+)?)')
      .firstMatch(label)?.group(1);
  if (number == null) return null;
  final volume = RegExp(r'(?:\(\s*(?:т\.?|том|vol\.?|volume)\s*|\b(?:том|volume|vol\.?)\s+)([0-9]+(?:\.[0-9]+)?)')
      .firstMatch(label)?.group(1) ?? '0';

  String normalize(String raw) {
    final parts = raw.split('.');
    final whole = BigInt.parse(parts.first).toString();
    if (parts.length == 1) return whole;
    final fraction = parts.last.replaceFirst(RegExp(r'0+$'), '');
    return fraction.isEmpty ? whole : whole + '.' + fraction;
  }
  try {
    return 'v' + normalize(volume) + ':c' + normalize(number);
  } on FormatException {
    return null;
  }
}

/// Compare decimal identities without lexical ordering or floating point loss.
/// Unknown labels have no ordering: only that exact selected chapter is marked.
int? compareChapterChronology(Chapter a, Chapter b) {
  final first = canonicalChapterKey(a);
  final second = canonicalChapterKey(b);
  if (first == null || second == null) return null;
  int decimal(String x, String y) {
    final xp = x.split('.');
    final yp = y.split('.');
    final whole = BigInt.parse(xp.first).compareTo(BigInt.parse(yp.first));
    if (whole != 0) return whole;
    final xf = xp.length == 2 ? xp.last : '';
    final yf = yp.length == 2 ? yp.last : '';
    final length = xf.length > yf.length ? xf.length : yf.length;
    return xf.padRight(length, '0').compareTo(yf.padRight(length, '0'));
  }
  final ap = first.substring(1).split(':c');
  final bp = second.substring(1).split(':c');
  final volume = decimal(ap.first, bp.first);
  return volume != 0 ? volume : decimal(ap.last, bp.last);
}

String sourceChapterKey(Chapter chapter, String source) =>
    '$source|${canonicalChapterKey(chapter) ?? 'id:${chapter.id}'}';


/// UI-only label: preserve the source name/id for canonical identity,
/// persistence, chapter ordering, and notification deduplication.
String displayChapterName(String name) {
  final withoutVolume = name.replaceAll(
    RegExp(r'\s*\(\s*(?:(?:т(?:ом)?|vol(?:ume)?)\.?\s*\.?\s*[0-9]+(?:[.,][0-9]+)?)\s*\)', caseSensitive: false), '');
  return withoutVolume.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
}
