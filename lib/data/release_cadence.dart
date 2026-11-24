/// When to check a title again, from the source's own chapter dates
/// (like Mihon's fetch window): often around the expected next release,
/// rarely in between. Without a clear rhythm the old fixed interval stays.
///
/// Source dates usually have day precision, so the "window" is a day or two,
/// not an hour. [maxDelay] bounds every pause, so an unscheduled release
/// (double chapter, return from hiatus) is still found within that time.
class ReleaseCadence {
  const ReleaseCadence({
    this.baseDelay = const Duration(minutes: 30),
    this.maxDelay = const Duration(hours: 3),
    this.minReleases = 4,
  });

  /// The interval used when the rhythm is unknown (the previous behavior).
  final Duration baseDelay;
  /// Safety net: never wait longer than this between successful checks.
  final Duration maxDelay;
  final int minReleases;

  /// Typical gap between releases, or null when there is no reliable rhythm.
  Duration? interval(Iterable<DateTime> releaseDates) {
    // Same-day batches count once; use the most recent releases only.
    final days = {for (final d in releaseDates) DateTime.utc(d.year, d.month, d.day)}
        .toList()..sort();
    if (days.length < minReleases) return null;
    final recent = days.length > 9 ? days.sublist(days.length - 9) : days;
    final gaps = [for (var i = 1; i < recent.length; i++)
      recent[i].difference(recent[i - 1])]..sort();
    final median = gaps[gaps.length ~/ 2];
    if (median < const Duration(days: 1) || median > const Duration(days: 60)) return null;
    // Irregular schedules: too many gaps far from the median → no rhythm.
    final off = gaps.where((g) =>
        (g - median).abs() > median * 0.5).length;
    if (off * 3 > gaps.length) return null;
    return median;
  }

  /// Delay before the next check of this title after a successful one.
  Duration nextDelay(Iterable<DateTime> releaseDates, DateTime now) {
    final every = interval(releaseDates);
    if (every == null) return baseDelay;
    final last = releaseDates.reduce((a, b) => a.isAfter(b) ? a : b);
    final lastDay = DateTime.utc(last.year, last.month, last.day);
    final expected = lastDay.add(every);
    // Day-precision dates: open the window a day early and keep it open
    // for a fraction of the interval after the expected day.
    final window = every * 0.15 > const Duration(days: 1)
        ? every * 0.15 : const Duration(days: 1);
    final opens = expected.subtract(const Duration(days: 1));
    final closes = expected.add(window);
    final nowUtc = now.toUtc();
    if (nowUtc.isBefore(opens)) {
      final wait = opens.difference(nowUtc);
      return _bounded(wait);
    }
    if (nowUtc.isBefore(closes)) return baseDelay; // release window: check often
    // Late: back off gradually, a long hiatus is checked at the safety pace.
    final late = nowUtc.difference(closes);
    if (late < every) return _bounded(const Duration(hours: 3));
    return maxDelay;
  }

  Duration _bounded(Duration value) =>
      value < baseDelay ? baseDelay : value > maxDelay ? maxDelay : value;
}
