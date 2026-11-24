import 'dart:async';
import 'dart:io';
import 'package:senreader/core/source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senreader/data/chapter_scan_trace.dart';

void main() {
  test('page/image HTTP status is logged as a fixed label, never the message', () async {
    final samples = <Object, String>{
      SourceException('HTTP 404. Сайт или зеркало недоступны. https://secret.example/x'): 'page_404',
      SourceException('ReadManga: изображение недоступно (HTTP 403).'): 'image_403',
      SourceException('Нет соединения с ReadManga (secret)'): 'network',
      const SocketException('secret'): 'network',
    };
    for (final item in samples.entries) {
      final lines = <String>[];
      final trace = ChapterScanTrace(output: lines.add);
      await expectLater(trace.run('manual', () => ChapterScanTrace.stage<void>(
        'source_pages', () async => throw item.key)), throwsA(same(item.key)));
      expect(lines.any((line) => line.endsWith('stage=source_pages_detail state=${item.value}')), true);
      expect(lines.join(), isNot(contains('secret')));
    }
  });

  test('Senkuro 200-with-error answers get a fixed label, not their text', () {
    expect(ChapterScanTrace.errorDetail(
      SourceException('Senkuro GraphQL: secret chapter text')), 'graphql_error');
    expect(ChapterScanTrace.errorDetail(
      SourceException('Некорректный ответ Senkuro')), 'invalid_response');
    expect(ChapterScanTrace.errorDetail(SourceException('что-то ещё')), '');
  });

  test('safe source categories retain exception and never print payload', () async {
    final samples = <Object, String>{
      TimeoutException('secret URL'): 'timeout',
      const SocketException('secret'): 'http',
      const FormatException('private payload'): 'parse',
      SourceException('HTTP 403 secret token'): 'http',
      SourceException('главы нет в публичном доступе'): 'unavailable',
      StateError('cancelled private URL'): 'unknown',
    };
    for (final item in samples.entries) {
      final lines = <String>[];
      final trace = ChapterScanTrace(output: lines.add);
      await expectLater(trace.run('manual', () => ChapterScanTrace.stage<void>(
        'source_pages', () async => throw item.key)), throwsA(same(item.key)));
      expect(lines.any((line) => line.endsWith('stage=source_pages_category state=${item.value}')), true);
      expect(lines.join(), isNot(contains('secret')));
      expect(lines.join(), isNot(contains('private')));
    }
  });

  test('Android stop shares active run id, does not fake completion or cancel data', () async {
    final lines = <String>[];
    final trace = ChapterScanTrace(output: lines.add);
    final pending = Completer<int>();
    final run = trace.run('dispatch', () => pending.future);
    trace.androidStopped('timeout');
    expect(lines.where((line) => line.contains('worker_stop_signal')),
      everyElement(contains('runId=${trace.id}')));
    expect(lines.any((line) => line.endsWith('state=end')), false);
    expect(lines.join(), contains('stage=run_stop_category state=cancelled'));
    pending.complete(3);
    expect(await run, 3);
  });

  test('stalled dependency reports waiting without falsely finishing or cancelling', () async {
    final lines = <String>[];
    final pending = Completer<int>();
    final trace = ChapterScanTrace(output: lines.add,
      waitAfter: const Duration(milliseconds: 5));
    var finished = false;
    final work = trace.run('manual', () => ChapterScanTrace.stage(
      'source_detail', () => pending.future)).then((v) { finished = true; return v; });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(finished, isFalse);
    expect(lines.any((s) => s.contains('stage=source_detail state=waiting')), isTrue);
    expect(lines.any((s) => s.endsWith('state=end')), isFalse);
    pending.complete(7);
    expect(await work, 7);
    expect(lines.last, contains('stage=manual state=end'));
  });

  test('source failure retains error identity, hides text, and permits retry', () async {
    final lines = <String>[];
    final trace = ChapterScanTrace(output: lines.add);
    final error = StateError('private title, URL, token');
    await expectLater(trace.run('manual', () async => throw error), throwsA(same(error)));
    expect(lines.join(), isNot(contains('private')));
    expect(await trace.run('manual', () async => 3), 3);
  });

  test('concurrent invocations keep independent stage identities', () async {
    final lines = <String>[];
    final one = ChapterScanTrace(output: lines.add);
    final two = ChapterScanTrace(output: lines.add);
    final gate = Completer<void>();
    final first = one.run('manual', () async {
      await gate.future;
      await ChapterScanTrace.stage('scan_state', () async {});
    });
    await two.run('workmanager', () async {
      await ChapterScanTrace.stage('run_insert', () async {});
    });
    gate.complete();
    await first;
    expect(lines.where((s) => s.contains('stage=scan_state')),
      everyElement(contains('id=${one.id}')));
    expect(lines.where((s) => s.contains('stage=run_insert')),
      everyElement(contains('id=${two.id}')));
  });

  test('diagnostic output failure cannot prevent completion', () async {
    final trace = ChapterScanTrace(output: (_) => throw StateError('logger'));
    expect(await trace.run('manual', () async => 42), 42);
  });
}
