import 'dart:convert';

import '../core/title_matching.dart';
import 'library_store.dart';

/// A lossless JSON snapshot. Use [toJson] for persistence, not SavedBook.fromJson:
/// an older SavedBook implementation may discard newer progress fields.
class TransferBook {
  TransferBook._(Map<String, dynamic> json) : _encoded = jsonEncode(json);
  final String _encoded;
  Map<String, dynamic> toJson() => jsonDecode(_encoded) as Map<String, dynamic>;
  String get title => toJson()['title'] as String;
  String get key => normalizedTitle(title);
  Map<String, String> get sourceIds =>
      (toJson()['entries'] as Map<String, dynamic>).map((key, value) =>
          MapEntry(key, (value as Map<String, dynamic>)['id'] as String));
}

class LibraryBackup {
  LibraryBackup._(this._encoded, List<TransferBook> books)
      : books = List.unmodifiable(books);
  final String _encoded;
  final List<TransferBook> books;

  /// Includes unknown envelope, book and entry fields without model conversion.
  String toJsonString() => _encoded;
}

enum ImportDisposition { newBook, existing, duplicate, conflict }

class ImportPreviewItem {
  ImportPreviewItem._(this.book, this.disposition, this.reason,
      Iterable<String> candidateKeys)
      : candidateKeys = List.unmodifiable(candidateKeys.toSet().toList()..sort());
  final TransferBook book;
  final ImportDisposition disposition;
  final String reason;
  final List<String> candidateKeys;
}

class LibraryImportPreview {
  LibraryImportPreview._(List<ImportPreviewItem> items)
      : items = List.unmodifiable(items);
  final List<ImportPreviewItem> items;
  int count(ImportDisposition disposition) =>
      items.where((item) => item.disposition == disposition).length;
  int get newCount => count(ImportDisposition.newBook);
  int get existingCount => count(ImportDisposition.existing);
  int get duplicateCount => count(ImportDisposition.duplicate);
  int get conflictCount => count(ImportDisposition.conflict);

  /// Only these records can be proposed as additions. No writes are performed.
  List<TransferBook> get additions => List.unmodifiable(items
      .where((item) => item.disposition == ImportDisposition.newBook)
      .map((item) => item.book));
}

/// Offline, bounded native backup validation and additions-only planning.
class LibraryTransfer {
  static const format = 'senreader-library';
  static const version = 1;
  static const maxBytes = 5 * 1024 * 1024;
  static const maxBooks = 5000;
  static const sources = {'senkuro', 'readmanga', 'remanga'};
  static const defaultCoverHosts = {
    'senkuro.com', 'remanga.org', 'a.zazaza.me', '3.readmanga.ru',
  };

  /// Extra CDN hosts must come from trusted application policy, never the file.
  const LibraryTransfer({this.trustedCoverHosts = defaultCoverHosts});
  final Set<String> trustedCoverHosts;

  String exportBooks(Iterable<SavedBook> books) => parse(jsonEncode({
        'format': format,
        'version': version,
        'books': books.map((book) => book.toJson()).toList(),
      })).toJsonString();

  LibraryBackup parseBytes(List<int> bytes) {
    if (bytes.length > maxBytes) _fail('Backup exceeds byte limit');
    return parse(utf8.decode(bytes, allowMalformed: false));
  }

  LibraryBackup parse(String input) {
    if (input.length > maxBytes || utf8.encode(input).length > maxBytes) {
      _fail('Backup exceeds byte limit');
    }
    // jsonDecode alone silently accepts repeated object keys. Inspect before it
    // runs, also bounding depth and token count (including opaque future fields).
    _JsonGuard(input).check();
    final root = _map(jsonDecode(input));
    if (root['format'] != format || root['version'] is! int ||
        root['version'] != version) {
      _fail('Unsupported backup format/version');
    }
    final rows = root['books'];
    if (rows is! List || rows.length > maxBooks) _fail('Invalid books list');
    final books = <TransferBook>[];
    for (final row in rows) {
      final book = _map(row);
      _validateBook(book);
      books.add(TransferBook._(book));
    }
    return LibraryBackup._(jsonEncode(root), books);
  }

  /// Local rows may be supplied losslessly from another backup, or snapshotted
  /// with [snapshot]. Neither input nor existing progress is ever changed.
  LibraryImportPreview preview(LibraryBackup backup,
      {Iterable<TransferBook> existing = const []}) {
    final local = existing.toList();
    final incoming = backup.books;
    final byTitle = <String, List<int>>{};
    final byIdentity = <String, List<int>>{};
    final all = [...local, ...incoming];
    final titleKeys = all.map((book) => book.key).toList();
    final signatures = all
        .map((book) => jsonEncode(_canonical(book.toJson())))
        .toList();
    for (var i = 0; i < all.length; i++) {
      byTitle.putIfAbsent(titleKeys[i], () => []).add(i);
      for (final identity in _identities(all[i])) {
        byIdentity.putIfAbsent(identity, () => []).add(i);
      }
    }
    final seen = <String>{};
    final items = <ImportPreviewItem>[];
    for (var i = 0; i < incoming.length; i++) {
      final book = incoming[i];
      final signature = signatures[local.length + i];
      final candidates = <int>{...?byTitle[titleKeys[local.length + i]]};
      for (final id in _identities(book)) {
        candidates.addAll(byIdentity[id] ?? const <int>[]);
      }
      candidates.remove(local.length + i);
      final hasCollision = candidates.any((index) => signatures[index] != signature);
      final keys = candidates.map((index) => titleKeys[index]);
      // Conflicts take precedence even over repeated records, so none of a
      // colliding import group can become an order-dependent safe addition.
      if (hasCollision) {
        items.add(ImportPreviewItem._(book, ImportDisposition.conflict,
            'Title/source collision or differing state; confirmation required', keys));
      } else if (!seen.add(signature)) {
        items.add(ImportPreviewItem._(book, ImportDisposition.duplicate,
            'Repeated identical import record', keys));
      } else if (candidates.any((index) => index < local.length)) {
        items.add(ImportPreviewItem._(book, ImportDisposition.existing,
            'Identical local record; keep local', keys));
      } else {
        items.add(ImportPreviewItem._(book, ImportDisposition.newBook,
            'Safe addition; no matching local title/source identity', const []));
      }
    }
    return LibraryImportPreview._(items);
  }

  List<TransferBook> snapshot(Iterable<SavedBook> books) =>
      parse(exportBooks(books)).books;

  static Iterable<String> _identities(TransferBook book) =>
      book.sourceIds.entries.map((entry) => jsonEncode([
            entry.key,
            // The adapter treats the legacy and current origins as the same
            // source. A path/host spelling difference must still flag ambiguity.
            entry.key == 'readmanga' ? Uri.parse(entry.value).path : entry.value,
          ]));

  void _validateBook(Map<String, dynamic> book) {
    final title = _string(book['title']);
    if (normalizedTitle(title).isEmpty) _fail('Empty normalized title');
    final entries = _map(book['entries']);
    if (entries.isEmpty || entries.length > sources.length) _fail('Invalid entries');
    for (final pair in entries.entries) {
      if (!sources.contains(pair.key)) _fail('Unknown source');
      final entry = _map(pair.value);
      if (entry['source'] != pair.key) _fail('Source key mismatch');
      if (normalizedTitle(_string(entry['title'])).isEmpty) _fail('Invalid entry title');
      final id = _string(entry['id']);
      if (pair.key == 'readmanga') {
        if (id.startsWith('/')) {
          if (!RegExp(r'^/[a-zA-Z0-9_-]+$').hasMatch(id)) _fail('Invalid title path');
        } else {
          final uri = _https(id, const {'a.zazaza.me', '3.readmanga.ru'});
          if (!RegExp(r'^/[a-zA-Z0-9_-]+$').hasMatch(uri.path)) {
            _fail('Invalid title URL path');
          }
        }
      } else if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
        _fail('Invalid source ID');
      }
      if (entry.containsKey('coverUrl')) {
        final cover = _string(entry['coverUrl'], allowEmpty: true);
        if (cover.isNotEmpty) _https(cover, trustedCoverHosts);
      }
    }
    for (final field in ['lastChapter', 'lastSource']) {
      if (book.containsKey(field)) _string(book[field], allowEmpty: true);
    }
    final lastSource = book['lastSource'];
    if (lastSource != null && lastSource != '' && !entries.containsKey(lastSource)) {
      _fail('Unknown last source');
    }
    if (book.containsKey('preferredSource')) {
      final preferred = _string(book['preferredSource']);
      if (!entries.containsKey(preferred)) _fail('Unknown preferred source');
    }
    if (book.containsKey('readHistoryVersion') && book['readHistoryVersion'] != 2) {
      _fail('Unsupported read history version');
    }
    _stringSet(book, 'readChapterKeys', 256);
    _stringSet(book, 'seenChapterKeys', 128);
    _stringSet(book, 'initializedSources', 32,
        allowed: entries.keys.toSet());
  }

  static void _stringSet(Map<String, dynamic> book, String field, int maxLength,
      {Set<String>? allowed}) {
    if (!book.containsKey(field)) return; // Early v1 records omit baselines.
    final value = book[field];
    if (value is! List || value.length > 20000) _fail('Invalid $field');
    final seen = <String>{};
    for (final item in value) {
      if (item is! String || item.isEmpty || item.length > maxLength ||
          !seen.add(item) || (allowed != null && !allowed.contains(item))) {
        _fail('Invalid or duplicate $field value');
      }
    }
  }

  static Uri _https(String value, Set<String> hosts) {
    final uri = Uri.tryParse(value);
    // Uri canonicalizes an explicit default port (:443), so hasPort alone
    // cannot enforce our no-explicit-port backup policy. Check raw authority.
    final rawAuthority = RegExp(r'^https://([^/?#]+)').firstMatch(value)?.group(1);
    if (uri == null || uri.scheme != 'https' || !uri.hasAuthority ||
        rawAuthority == null || rawAuthority.contains(':') ||
        !hosts.contains(uri.host) || uri.userInfo.isNotEmpty ||
        uri.hasPort || uri.hasQuery || uri.hasFragment ||
        RegExp(r'[\s\\\x00-\x1f\x7f%]').hasMatch(value) ||
        uri.pathSegments.any((part) => part == '.' || part == '..')) {
      _fail('Untrusted or invalid HTTPS URL');
    }
    return uri;
  }

  static String _string(dynamic value, {bool allowEmpty = false}) {
    if (value is! String || value.length > 4096 ||
        (!allowEmpty && value.trim().isEmpty) ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) _fail('Invalid string');
    return value;
  }

  static Map<String, dynamic> _map(dynamic value) {
    if (value is! Map<String, dynamic>) _fail('Expected JSON object');
    return value;
  }

  static dynamic _canonical(dynamic value) {
    if (value is Map<String, dynamic>) {
      return {for (final key in value.keys.toList()..sort()) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }

  static Never _fail(String message) => throw FormatException(message);
}

/// Structural preflight; JSON's full scalar/escape grammar is checked by
/// jsonDecode afterwards. Object keys are decoded here to catch escaped aliases.
class _JsonGuard {
  _JsonGuard(this.input);
  final String input;
  int offset = 0;
  int tokens = 0;
  Never fail() => throw const FormatException('Invalid or excessive JSON structure');
  void whitespace() {
    while (offset < input.length && ' \r\n\t'.contains(input[offset])) {
      offset++;
    }
  }

  void check() {
    value(0);
    whitespace();
    if (offset != input.length) fail();
  }

  String string() {
    final start = offset++;
    while (offset < input.length) {
      final char = input[offset++];
      if (char == '"') return jsonDecode(input.substring(start, offset)) as String;
      if (char == '\\') offset++;
    }
    fail();
  }

  void value(int depth) {
    if (depth > 32 || ++tokens > 250000) fail();
    whitespace();
    if (offset >= input.length) fail();
    final char = input[offset];
    if (char == '"') {
      string();
    } else if (char == '{' || char == '[') {
      offset++;
      final close = char == '{' ? '}' : ']';
      final keys = <String>{};
      whitespace();
      if (offset < input.length && input[offset] == close) {
        offset++;
        return;
      }
      while (true) {
        whitespace();
        if (char == '{') {
          if (offset >= input.length || input[offset] != '"') fail();
          if (!keys.add(string())) fail();
          whitespace();
          if (offset >= input.length || input[offset++] != ':') fail();
        }
        value(depth + 1);
        whitespace();
        if (offset >= input.length) fail();
        final separator = input[offset++];
        if (separator == close) return;
        if (separator != ',') fail();
      }
    } else {
      final start = offset;
      while (offset < input.length && !',]} \r\n\t'.contains(input[offset])) {
        offset++;
      }
      if (start == offset) fail();
    }
  }
}
