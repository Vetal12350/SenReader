import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/data/chapter_background_scheduler.dart';
import 'package:workmanager/workmanager.dart';

/// B1: background chapter checks need only a network connection. A
/// battery-not-low requirement silently blocked checks on a partly charged
/// phone and must not come back.
void main() {
  test('chapter check work requires network and nothing battery-related', () {
    final constraints = chapterCheckConstraints();
    expect(constraints.networkType, NetworkType.connected);
    expect(constraints.requiresBatteryNotLow, isNot(true));
    expect(constraints.requiresCharging, isNot(true));
    expect(constraints.requiresDeviceIdle, isNot(true));
  });
}
