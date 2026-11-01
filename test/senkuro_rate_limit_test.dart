import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:senreader/data/senkuro_request_gate.dart';
import 'package:senreader/data/senkuro_source.dart';

http.Response _success() => http.Response(
    jsonEncode({'data': {'mangas': {'edges': []}}}), 200);

void main() {
  test('Retry-After handles seconds, HTTP dates and invalid values', () {
    final now = DateTime.utc(2026, 11, 1, 12);
    expect(SenkuroRequestGate.parseRetryAfter('12'), const Duration(seconds: 12));
    expect(SenkuroRequestGate.parseRetryAfter('-3'), Duration.zero);
    expect(SenkuroRequestGate.parseRetryAfter(
      HttpDate.format(now.add(const Duration(seconds: 25))), now: now),
      const Duration(seconds: 25));
    expect(SenkuroRequestGate.parseRetryAfter('bad'), isNull);
  });

  test('HTTP 429 is retried once with server cooldown, not surfaced raw', () async {
    var calls = 0;
    final waits = <Duration>[];
    final source = SenkuroSource(
      client: MockClient((request) async {
        calls++;
        if (calls == 1) {
          return http.Response('rate limited', 429,
              headers: {'retry-after': '2'});
        }
        return _success();
      }),
      requestGate: SenkuroRequestGate(
        minimumSpacing: Duration.zero,
        sleeper: (duration) async { waits.add(duration); },
      ),
    );
    expect(await source.popular(), isEmpty);
    expect(calls, 2);
    expect(waits.any((value) => value.inSeconds >= 1), isTrue);
  });

  test('repeated 429 has a bounded number of calls', () async {
    var calls = 0;
    final source = SenkuroSource(
      client: MockClient((_) async {
        calls++;
        return http.Response('limit', 429);
      }),
      requestGate: SenkuroRequestGate(
        minimumSpacing: Duration.zero,
        fallbackDelay: Duration.zero,
        sleeper: (_) async {},
      ),
    );
    await expectLater(source.popular(), throwsA(isA<StateError>()));
    expect(calls, 2);
  });

  test('concurrent Senkuro calls use one request slot at a time', () async {
    var active = 0;
    var peak = 0;
    var calls = 0;
    final source = SenkuroSource(
      client: MockClient((_) async {
        active++;
        calls++;
        if (active > peak) peak = active;
        await Future<void>.delayed(Duration.zero);
        active--;
        return _success();
      }),
      requestGate: SenkuroRequestGate(minimumSpacing: Duration.zero),
    );
    await Future.wait([
      source.popular(),
      source.browseHome(),
      source.browseHome(type: 'MANHWA'),
    ]);
    expect(calls, 3);
    expect(peak, 1);
  });
}
