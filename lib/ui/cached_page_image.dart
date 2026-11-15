import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import '../core/models.dart';
import '../data/page_disk_cache.dart';

/// Reader page image: local file from [PageDiskCache] when present, otherwise
/// the network (same HTTP semantics as [NetworkImage]) with the bytes stored
/// for the next time. Identity is the URL, like [NetworkImage].
class CachedPageImage extends ImageProvider<CachedPageImage> {
  const CachedPageImage(this.page, {this.cache, this.fetch});
  final PageImage page;
  final PageDiskCache? cache;
  /// Test seam for the network path.
  final Future<Uint8List> Function(PageImage page)? fetch;

  @override
  Future<CachedPageImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<CachedPageImage>(this);

  @override
  ImageStreamCompleter loadImage(CachedPageImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1,
        debugLabel: page.url);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async =>
      decode(await ui.ImmutableBuffer.fromUint8List(await loadBytes()));

  /// Encoded page bytes: the cached file when present and readable,
  /// otherwise the network, stored for next time (best effort).
  @visibleForTesting
  Future<Uint8List> loadBytes() async {
    final store = cache ?? PageDiskCache.instance;
    final file = await store.cached(page.url);
    if (file != null) {
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) return bytes;
      } catch (_) {/* Corrupt or evicted mid-read: use the network. */}
    }
    final bytes = await (fetch ?? _network)(page);
    if (bytes.isEmpty) throw StateError('Empty page image');
    unawaited(store.store(page.url, bytes));
    return bytes;
  }

  static final HttpClient _client = HttpClient()..autoUncompress = false;

  static Future<Uint8List> _network(PageImage page) async {
    final uri = Uri.parse(page.url);
    final request = await _client.getUrl(uri);
    page.headers.forEach((name, value) => request.headers.add(name, value));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<List<int>>(<int>[]);
      throw NetworkImageLoadException(statusCode: response.statusCode, uri: uri);
    }
    return consolidateHttpClientResponseBytes(response);
  }

  @override
  bool operator ==(Object other) =>
      other is CachedPageImage && other.page.url == page.url;

  @override
  int get hashCode => page.url.hashCode;

  @override
  String toString() => 'CachedPageImage(${page.url})';
}
