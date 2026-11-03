/// Small speculative window, independent of title/source or reading activity.
/// Bitmap-cache occupancy reduces concurrency; it never changes visible quality.
class ReaderPrefetchPolicy {
  static int concurrency(int bytes, int maximumBytes, {bool memoryPressure = false}) =>
      memoryPressure || maximumBytes <= 0 || bytes >= maximumBytes * .75 ? 1 : 2;

  static List<int> candidates({required int first, required int last,
      required int count, required bool forward, required double velocity,
      required double viewport, bool memoryPressure = false}) {
    final ahead = memoryPressure ? 1 : velocity.abs() > viewport ? 4 : 2;
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

  static int decodedBytes(int width, double ratio) =>
      (width * width * ratio * 4).ceil();
}
