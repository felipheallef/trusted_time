import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts;
import 'package:trusted_time/src/sources/nts_source.dart';
import 'package:trusted_time/trusted_time.dart';

nts.NtsTimeSample receipt({
  int utcMicros = 1000000000,
  int rttMicros = 20000,
  int peerDelayMicros = 0,
  int rootDelayMicros = 0,
  int rootDispersionMicros = 0,
  int receivedMicros = 1000000,
  int generation = 7,
  nts.ClockBackend? backend = nts.ClockBackend.appleContinuous,
}) => nts.NtsTimeSample(
  utcUnixMicros: utcMicros,
  roundTripMicros: rttMicros,
  peerDelayMicros: peerDelayMicros,
  rootDelayMicros: rootDelayMicros,
  rootDispersionMicros: rootDispersionMicros,
  serverStratum: 1,
  aeadId: 15,
  freshCookies: 8,
  phaseTimings: const nts.PhaseTimings(
    dnsMicros: 0,
    connectMicros: 0,
    tlsHandshakeMicros: 0,
    keRecordIoMicros: 0,
  ),
  trustBackend: nts.TrustBackend.platform,
  recvBoottimeMicros: receivedMicros,
  recvClockGeneration: generation,
  recvClockBackend: backend,
);

TimeSample convert(nts.NtsTimeSample sample, {int bracketMicros = 0}) =>
    ntsSampleToTimeSample(
      sample,
      sourceId: 'nts:test',
      groupId: 'test',
      queryStartMicros: 900000,
      beforeUptimeMicros: 1005000,
      afterUptimeMicros: 1005000 + bracketMicros,
      uptimeMs: 800000,
      generation: 7,
      backend: nts.ClockBackend.appleContinuous,
      oscillatorDriftFactor: 0,
    );

void main() {
  test(
    'custom-trust source construction does not require native initialization',
    () {
      final source = NtsSource(
        'time.cloudflare.com',
        trustMode: nts.TrustMode.bundledOnly,
      );
      expect(source.id, 'nts:time.cloudflare.com');
      source.dispose();
    },
  );

  test('corrects one-way delay and native-to-Dart lag exactly once', () {
    final sample = convert(receipt());
    expect(sample.interval.startMs, 1000005);
    expect(sample.interval.endMs, 1000025);
    expect(sample.uptimeMs, 800000);
    expect(sample.authLevel, NtsAuthLevel.verified);
  });

  test('selects plausible peer delay instead of raw RTT', () {
    expect(convert(receipt(peerDelayMicros: 12000)).interval.midpoint, 1000011);
    for (final delay in [-1, 0, 20001]) {
      expect(
        convert(receipt(peerDelayMicros: delay)).interval.midpoint,
        1000015,
      );
    }
  });

  test('includes root delay and dispersion in uncertainty', () {
    final sample = convert(
      receipt(rootDelayMicros: 6000, rootDispersionMicros: 2000),
    );
    expect(sample.interval.startMs, 1000000);
    expect(sample.interval.endMs, 1000030);
  });

  test(
    'bounds asynchronous clock sampling without comparing clock origins',
    () {
      final sample = convert(receipt(), bracketMicros: 8000);
      expect(sample.interval.startMs, 1000005);
      expect(sample.interval.endMs, 1000033);
      expect(sample.uptimeMs, 800000);
    },
  );

  test('rounds sub-millisecond and negative UTC bounds outwards', () {
    final positive = convert(receipt(utcMicros: 501, rttMicros: 1));
    expect(positive.interval.startMs, 5);
    expect(positive.interval.endMs, 6);
    final negative = convert(receipt(utcMicros: -5501, rttMicros: 1));
    expect(negative.interval.startMs, -1);
    expect(negative.interval.endMs, 0);
  });

  test('rejects absent, foreign, stale, and future receipt provenance', () {
    for (final sample in [
      receipt(generation: 0),
      receipt(generation: 8),
      receipt(backend: null),
      receipt(backend: nts.ClockBackend.linuxBoottime),
      receipt(receivedMicros: 899999),
      receipt(receivedMicros: 1005001),
      receipt(rttMicros: -1),
    ]) {
      expect(() => convert(sample), throwsA(isA<TrustedTimeSyncException>()));
    }
  });

  test('rejects regression during the engine clock bracket', () {
    expect(
      () => convert(receipt(), bracketMicros: -1),
      throwsA(isA<TrustedTimeSyncException>()),
    );
  });

  test(
    'bounds drift accumulated between native receipt and clock sampling',
    () {
      final sample = ntsSampleToTimeSample(
        receipt(),
        sourceId: 'nts:test',
        groupId: 'test',
        queryStartMicros: 900000,
        beforeUptimeMicros: 11000000,
        afterUptimeMicros: 11000000,
        uptimeMs: 800000,
        generation: 7,
        backend: nts.ClockBackend.appleContinuous,
        oscillatorDriftFactor: 0.001,
      );
      expect(sample.uncertaintyMs, 20);
    },
  );
}
