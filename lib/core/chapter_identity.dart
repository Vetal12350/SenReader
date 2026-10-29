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
