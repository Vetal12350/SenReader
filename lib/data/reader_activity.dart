import 'package:flutter/foundation.dart';

/// How many reader screens are currently mounted in this (UI) isolate.
///
/// Foreground chapter scans parse source HTML and reload the library on the
/// UI isolate; they must not compete with reader frames. WorkManager scans
/// run in their own background engine and are not affected by this value.
class ReaderActivity {
  ReaderActivity._();
  static final ValueNotifier<int> open = ValueNotifier<int>(0);
  static bool get isOpen => open.value > 0;
  static void enter() => open.value++;
  static void leave() {
    if (open.value > 0) open.value--;
  }
}
