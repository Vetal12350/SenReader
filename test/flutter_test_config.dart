import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:senreader/data/chapter_inbox_store.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  sqfliteFfiInit();
  // Keep native database calls on this test isolate so widget-test fake
  // clocks do not wait on an unrelated FFI helper isolate. Production uses
  // Android sqflite; SQL constraints/transactions are exercised unchanged.
  databaseFactory = databaseFactoryFfiNoIsolate;
  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('senreader-inbox-test-');
    ChapterInboxStore.databasePathOverride = '${dir.path}/inbox.db';
    addTearDown(() async {
      await databaseFactory.deleteDatabase(ChapterInboxStore.databasePathOverride!);
      await dir.delete(recursive: true);
    });
  });
  await testMain();
}
