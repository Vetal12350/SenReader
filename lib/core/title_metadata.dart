/// Presentation-only cleaning: never invent missing source metadata.
List<String> distinctAlternativeNames(String title, Iterable<String> sourceNames) {
  String norm(String s) => s.trim().replaceAll(RegExp(r'\\s+'), ' ').toLowerCase();
  final seen = <String>{norm(title)};
  final result = <String>[];
  for (final raw in sourceNames) {
    final value = raw.trim().replaceAll(RegExp(r'\\s+'), ' ');
    if (value.isEmpty || !seen.add(norm(value))) continue;
    result.add(value);
  }
  return result;
}
