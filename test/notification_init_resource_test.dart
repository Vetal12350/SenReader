import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/data/chapter_notification_service.dart';

void main() {
  test('release icon permits initialization and repeat without publishing', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'initialize') {
        // Actual Pixel371 resource lookup: legacy ic_launcher=0,
        // drawable/senreader_launcher_monochrome exists.
        if ((call.arguments as Map)['defaultIcon'] != 'senreader_launcher_monochrome') {
          throw PlatformException(code: 'invalid_icon', message: 'Resource not found');
        }
        return true;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await ChapterNotificationService.instance.initialize(captureTaps: false);
    await ChapterNotificationService.instance.initialize(captureTaps: false);
    expect(calls, ['initialize', 'createNotificationChannel', 'initialize', 'createNotificationChannel']);
  });
  test('native initialization failure propagates and permits a later retry', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var fail = true;
    var channels = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'initialize') {
        if (fail) throw PlatformException(code: 'synthetic_failure');
        return true;
      }
      if (call.method == 'createNotificationChannel') channels++;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await expectLater(ChapterNotificationService.instance.initialize(captureTaps: false),
      throwsA(isA<PlatformException>()));
    expect(channels, 0);
    fail = false;
    await ChapterNotificationService.instance.initialize(captureTaps: false);
    expect(channels, 1);
  });
}
