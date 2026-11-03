import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/monotonic_clock.dart';
import 'package:trusted_time/src/sync_engine.dart';
import 'package:trusted_time/trusted_time.dart';

class _Clock implements MonotonicClock {
  int uptime = 100000;

  @override
  Future<int> uptimeMs() async => uptime;
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

TimeSample sample(String id, int utc, int uptime, {int uncertainty = 10}) =>
    TimeSample(
      sourceId: id,
      groupId: id,
      interval: TimeInterval(
        startMs: utc - uncertainty,
        endMs: utc + uncertainty,
      ),
      uptimeMs: uptime,
      authLevel: NtsAuthLevel.verified,
    );

void main() {
  late _Clock clock;
  late SyncEngine engine;

  SyncEngine create(List<TimeSource> sources, {int minimumQuorum = 2}) =>
      SyncEngine(
        config: TrustedTimeConfig(
          ntpServers: [],
          ntsServers: [],
          httpsSources: [],
          additionalSources: sources,
          earlyExit: false,
          minimumQuorum: minimumQuorum,
        ),
        clock: clock,
      );

  setUp(() => clock = _Clock());
  tearDown(() => engine.dispose());

  test(
    'replays reported three-provider cycle on a common monotonic instant',
    () async {
      final observations = [
        ('cloudflare', 1793654072878 + 8, 175, 8),
        ('ntpbr', 1793654073076 + 28, 401, 28),
        ('netnod', 1793654074254 + 114, 1675, 114),
      ];
      engine = create([
        for (final observation in observations)
          _Source(observation.$1, () async {
            clock.uptime = 100000 + observation.$3;
            return sample(
              observation.$1,
              observation.$2,
              clock.uptime,
              uncertainty: observation.$4,
            );
          }),
      ]);
      clock.uptime = 100000;
      final anchor = await engine.sync();
      expect(anchor.networkUtcMs, closeTo(1793654072711 + 1675, 10));
      expect(anchor.uptimeMs, 101675);
      expect(anchor.authLevel, NtsAuthLevel.verified);
    },
  );

  test('advances the anchor while waiting for a slow failed query', () async {
    engine = create([
      _Source('first', () async => sample('first', 1000000, 100000)),
      _Source('second', () async => sample('second', 1000000, 100000)),
      _Source('slow', () async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        clock.uptime += 1500;
        throw StateError('unreachable');
      }),
    ]);
    final anchor = await engine.sync();
    expect(anchor.networkUtcMs, 1001500);
    expect(anchor.uptimeMs, 101500);
  });

  test(
    'minimumQuorum counts actual agreeing participants, not retained samples',
    () async {
      engine = create([
        _Source('first', () async => sample('first', 1000000, 100000)),
        _Source('second', () async => sample('second', 1000000, 100000)),
        _Source('outlier', () async => sample('outlier', 2000000, 100000)),
      ], minimumQuorum: 3);
      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );
    },
  );

  test(
    'refuses samples from before the synchronization clock reference',
    () async {
      engine = create([
        _Source('first', () async => sample('first', 1000000, 99999)),
        _Source('second', () async => sample('second', 1000000, 99999)),
      ]);
      await expectLater(
        engine.sync(),
        throwsA(isA<TrustedTimeSyncException>()),
      );
    },
  );
}
