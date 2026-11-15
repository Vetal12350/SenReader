/// Small speculative window, independent of title/source or reading activity.
/// Bitmap-cache occupancy reduces concurrency; it never changes visible quality.
class ReaderPrefetchPolicy {
  /// Pages are read from the local disk cache (C2), so decoding, not the
  /// network, limits readiness. Throttle only when the bitmap cache is nearly
  /// full or Android reports memory pressure.
  static int concurrency(int bytes, int maximumBytes, {bool memoryPressure = false}) =>
      memoryPressure || maximumBytes <= 0 || bytes >= maximumBytes * .9 ? 1 :
      bytes >= maximumBytes * .75 ? 2 : 3;

  static List<int> candidates({required int first, required int last,
      required int count, required bool forward, required double velocity,
      required double viewport, bool memoryPressure = false}) {
    // Decode (and learn the height of) pages well before they scroll in:
    // a tall strip takes tens to hundreds of ms on the image thread.
    final ahead = memoryPressure ? 1 : velocity.abs() > viewport ? 6 : 4;
    final result = <int>[];
    void add(int index) {
      if (index >= 0 && index < count) result.add(index);
    }
    for (var step = 1; step <= ahead; step++) {
      add(forward ? last + step : first - step);
    }
    if (!memoryPressure) add(forward ? first - 1 : last + 1);
    return result;
  }

  /// Bitmap budget while a reader is open (restored when it closes or on
  /// memory pressure). Flutter's default is 100 MB, which a few decoded
  /// webtoon strips fill, evicting pages just above and below the viewport.
  static const readerCacheBytes = 320 << 20;
  static const readerCacheEntries = 400;

  static int decodedBytes(int width, double ratio) =>
      (width * width * ratio * 4).ceil();
}
