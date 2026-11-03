import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/monotonic_clock.dart';
import 'package:trusted_time/src/sync_engine.dart';
import 'package:trusted_time/trusted_time.dart';

class _FixedClock implements MonotonicClock {
  @override
  Future<int> uptimeMs() async => 100000;
}

class _ElapsedClock implements MonotonicClock {
  _ElapsedClock(this.elapsed);
  final Stopwatch elapsed;

  @override
  Future<int> uptimeMs() async => 100000 + elapsed.elapsedMilliseconds;
}

class _Source implements TimeSource {
  _Source(this.id, this.query);

  @override
  final String id;
  final Future<TimeSample> Function() query;

  @override
  String get groupId => id;

  @override
  Future<TimeSample> getTime() => query();
}

TimeSource _sample(String id, int utcMs, {int uncertaintyMs = 10}) =>
    _Source(id, () async {
      return TimeSample(
        interval: TimeInterval(
          startMs: utcMs - uncertaintyMs,
          endMs: utcMs + uncertaintyMs,
        ),
        sourceId: id,
        groupId: id,
        authLevel: NtsAuthLevel.verified,
      );
    });

void main() {
  late DebugPrintCallback originalPrint;
  late List<String> messages;
  late SyncEngine engine;

  SyncEngine createEngine(
    List<TimeSource> sources, {
    bool enableDiagnostics = true,
    Duration maxLatency = const Duration(seconds: 4),
    MonotonicClock? clock,
  }) {
    return SyncEngine(
      config: TrustedTimeConfig(
        ntpServers: [],
        ntsServers: [],
        httpsSources: [],
        additionalSources: sources,
        enableDiagnostics: enableDiagnostics,
        maxLatency: maxLatency,
      ),
      clock: clock ?? _FixedClock(),
    );
  }

  setUp(() {
    originalPrint = debugPrint;
    messages = [];
    debugPrint = (message, {wrapWidth}) {
      if (message != null) messages.add(message);
    };
  });

  tearDown(() {
    engine.dispose();
    debugPrint = originalPrint;
  });

  test('diagnostics default to disabled', () {
    engine = createEngine([]);
    expect(const TrustedTimeConfig().enableDiagnostics, isFalse);
  });

  test(
    'reports missing source and disjoint intervals without weakening quorum',
    () async {
      engine = createEngine([
        _sample('nts:first', 10000),
        _sample('nts:second', 11000),
        _Source(
          'nts:unreachable',
          () async => throw StateError('UDP unavailable'),
        ),
      ]);

      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );

      final output = messages.join('\n');
      expect(output, contains('[TrustedTime][sync=1] start configured=3'));
      expect(output, contains('maxLatencyMs=4000 ntsTimeoutMs=5000'));
      expect(output, contains('query failed source=nts:unreachable'));
      expect(output, contains('UDP unavailable'));
      expect(output, contains('cooldownMinutes=2'));
      expect(output, contains('retained=2 engineEligible=2 requiredOverlap=2'));
      expect(output, contains('alignedOverlap=false alignedGapMs=978'));
      expect(output, contains('receiptDeltaMs='));
      expect(output, contains('basisUptimeMs=100000'));
      expect(output, contains('auth=verified'));
      expect(output, contains('failed elapsedMs='));
    },
  );

  test('shows outer timeouts and source cooldown on the next cycle', () async {
    engine = createEngine([
      _sample('nts:first', 10000),
      _sample('nts:second', 11000),
      _Source('nts:slow', () => Completer<TimeSample>().future),
    ], maxLatency: const Duration(milliseconds: 20));

    await expectLater(engine.sync(), throwsA(isA<TrustedTimeSyncException>()));
    expect(messages.join('\n'), contains('errorType=TimeoutException'));

    messages.clear();
    await expectLater(engine.sync(), throwsA(isA<TrustedTimeSyncException>()));

    final output = messages.join('\n');
    expect(output, contains('[TrustedTime][sync=2] skip source=nts:slow'));
    expect(output, contains('reason=cooldown remainingMs='));
    expect(output, isNot(contains('query start source=nts:slow')));
  });

  test(
    'distinguishes retained samples from uncertainty-filtered samples',
    () async {
      engine = createEngine([
        _sample('nts:precise', 10000),
        _sample('nts:noisy', 10000, uncertaintyMs: 6000),
      ]);

      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );

      final output = messages.join('\n');
      expect(output, contains('retained=2 engineEligible=1'));
      expect(output, contains('uncertaintyMs=6001 engineEligible=false'));
    },
  );

  test('does not emit diagnostic logs when disabled', () async {
    engine = createEngine([
      _sample('nts:first', 10000),
      _sample('nts:second', 11000),
    ], enableDiagnostics: false);

    await expectLater(engine.sync(), throwsA(isA<TrustedTimeSyncException>()));

    expect(messages, isEmpty);
  });

  test('aligns accurate clocks observed at different instants', () async {
    final elapsed = Stopwatch()..start();
    final fastSampleRead = Completer<void>();

    TimeSource advancingSource(String id, Duration delay) {
      return _Source(id, () async {
        if (delay == Duration.zero) {
          fastSampleRead.complete();
        } else {
          await fastSampleRead.future;
          await Future<void>.delayed(delay);
        }
        final timestampMs = 1000000 + elapsed.elapsedMilliseconds;
        return TimeSample(
          interval: TimeInterval(
            startMs: timestampMs - 1,
            endMs: timestampMs + 1,
          ),
          sourceId: id,
          groupId: id,
          authLevel: NtsAuthLevel.verified,
        );
      });
    }

    engine = createEngine([
      advancingSource('nts:fast', Duration.zero),
      advancingSource('nts:slow', const Duration(milliseconds: 80)),
    ], clock: _ElapsedClock(elapsed));

    final anchor = await engine.sync();
    expect(anchor.networkUtcMs, closeTo(1000000 + anchor.uptimeMs - 100000, 3));
    expect(messages.join('\n'), contains('shiftMs='));
    expect(messages.join('\n'), contains('success elapsedMs='));
  });

  test(
    'still establishes authenticated consensus for agreeing sources',
    () async {
      engine = createEngine([
        _sample('nts:first', 10000),
        _sample('nts:second', 10001),
      ]);

      final anchor = await engine.sync();

      expect(anchor.authLevel, NtsAuthLevel.verified);
      expect(anchor.networkUtcMs, closeTo(10000, 10));
      expect(messages.join('\n'), contains('success elapsedMs='));
    },
  );
}
