import 'models.dart';

abstract class MangaSource {
  String get key;
  String get name;
  Map<String, String> get imageHeaders;
  Future<List<MangaEntry>> popular();
  Future<List<MangaEntry>> search(String query);
  Future<MangaDetail> detail(MangaEntry entry);
  Future<List<PageImage>> pages(Chapter chapter);
}

class SourceException implements Exception {
  SourceException(this.message);
  final String message;
  @override
  String toString() => message;
}
