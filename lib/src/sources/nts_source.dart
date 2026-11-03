import 'package:nts/nts.dart' as nts;

import '../domain/time_sample.dart';
import '../domain/time_source.dart';
import '../domain/time_interval.dart';
import '../models.dart';
import '../exceptions.dart';
import '../monotonic_clock.dart';
import 'nts_auth_level.dart';

/// RFC 8915-compliant NTS (Network Time Security) time source.
///
/// Uses [package:nts](https://pub.dev/packages/nts) which provides a
/// Rust-based implementation via `flutter_rust_bridge` with proper
/// TLS 1.3 keying material exporter support (RFC 5705).
///
/// This implementation is **fully conformant** with RFC 8915:
/// - Proper AEAD key derivation via TLS exporter
/// - AES-SIV-CMAC-256 authenticated encryption
/// - Secure NTPv4 extension field handling
///
/// **Platform support:** Android, iOS, macOS, Windows, Linux.
/// Not available on Web (NTS requires TLS 1.3 with exporters).
///
/// **Zero overhead when unused:** When [TrustedTimeConfig.ntsServers] is
/// empty (the default), no NTS connections are made.
final class NtsSource implements TimeSource {
  /// Creates an NTS source for the given NTS-KE server.
  ///
  /// [onStratumObserved] is called with the NTP stratum reported by the server
  /// after each successful query. Used by [SyncEngine] to feed stratum hints
  /// into [SourceQualityTracker] without widening [TimeSample].
  NtsSource(
    this._host, {
    int port = 4460,
    nts.TrustMode trustMode = nts.TrustMode.platformWithFallback,
    List<int>? customRoots,
    int timeoutMs = 5000,
    void Function(int)? onStratumObserved,
    MonotonicClock? clock,
    double oscillatorDriftFactor = 0.00005,
  }) : _port = port,
       _timeoutMs = timeoutMs,
       _onStratumObserved = onStratumObserved,
       _clock = clock ?? PlatformMonotonicClock(),
       _oscillatorDriftFactor = oscillatorDriftFactor,
       _trustMode = trustMode,
       _customRoots = customRoots;

  final String _host;
  final int _port;
  final int _timeoutMs;
  final void Function(int)? _onStratumObserved;
  final MonotonicClock _clock;
  final double _oscillatorDriftFactor;
  final nts.TrustMode _trustMode;
  final List<int>? _customRoots;
  nts.NtsClient? _client;

  @override
  String get id => '${TimeSource.prefixNts}$_host';

  @override
  String get groupId => _host;

  /// Whether this source is cryptographically secure.
  /// Returns `true` — this implementation uses proper RFC 8915 AEAD
  /// authentication via TLS keying material exporters.
  bool get isSecure => true;

  @override
  Future<TimeSample> getTime() async {
    await nts.NtsBridge.ensureInitialized();
    final context = nts.StrictClockContext.resolve();
    final dispatched = context.now();
    final spec = nts.NtsServerSpec(host: _host, port: _port);
    if (_trustMode != nts.TrustMode.platformWithFallback ||
        _customRoots != null) {
      _client ??= nts.NtsClient(
        trustMode: _trustMode,
        customRoots: _customRoots,
      );
    }
    final timeout = Duration(milliseconds: _timeoutMs);
    final client = _client;
    final result = client != null
        ? await client.query(spec: spec, timeout: timeout, context: context)
        : await nts.ntsQuery(spec: spec, timeout: timeout, context: context);
    final before = context.now();
    final uptimeMs = await _clock.uptimeMs();
    final after = context.now();

    // Report stratum to quality tracker if a listener is registered.
    _onStratumObserved?.call(result.serverStratum);

    return ntsSampleToTimeSample(
      result,
      sourceId: id,
      groupId: groupId,
      queryStartMicros: dispatched.micros,
      beforeUptimeMicros: before.micros,
      afterUptimeMicros: after.micros,
      uptimeMs: uptimeMs,
      generation: context.generation,
      backend: context.descriptor.backend,
      oscillatorDriftFactor: _oscillatorDriftFactor,
    );
  }

  /// Releases an owned client without resetting the process-wide NTS bridge.
  void dispose() => _client?.dispose();
}

/// Converts a provenance-checked NTS receipt to the engine's uptime coordinate.
TimeSample ntsSampleToTimeSample(
  nts.NtsTimeSample result, {
  required String sourceId,
  required String groupId,
  required int queryStartMicros,
  required int beforeUptimeMicros,
  required int afterUptimeMicros,
  required int uptimeMs,
  required int generation,
  required nts.ClockBackend backend,
  double oscillatorDriftFactor = 0.00005,
}) {
  if (result.recvClockGeneration == 0 ||
      result.recvClockGeneration != generation ||
      result.recvClockBackend != backend ||
      result.recvBoottimeMicros < queryStartMicros ||
      result.recvBoottimeMicros > beforeUptimeMicros ||
      afterUptimeMicros < beforeUptimeMicros ||
      uptimeMs < 0 ||
      result.roundTripMicros < 0) {
    throw TrustedTimeSyncException('NTS receipt has invalid clock provenance.');
  }
  final peerDelay = result.peerDelayMicros;
  final delayMicros = peerDelay > 0 && peerDelay <= result.roundTripMicros
      ? peerDelay
      : result.roundTripMicros;
  final lagMicros = beforeUptimeMicros - result.recvBoottimeMicros;
  final centerMicros = result.utcUnixMicros + delayMicros ~/ 2 + lagMicros;
  final rootDelay = result.rootDelayMicros > 0 ? result.rootDelayMicros : 0;
  final rootDispersion = result.rootDispersionMicros > 0
      ? result.rootDispersionMicros
      : 0;
  final uncertaintyMicros =
      (result.roundTripMicros + 1) ~/ 2 +
      (rootDelay + 1) ~/ 2 +
      rootDispersion +
      ((afterUptimeMicros - result.recvBoottimeMicros) * oscillatorDriftFactor)
          .ceil();
  final lowerMicros = centerMicros - uncertaintyMicros;
  final upperMicros =
      centerMicros + uncertaintyMicros + afterUptimeMicros - beforeUptimeMicros;
  int floorMs(int micros) =>
      micros ~/ 1000 - (micros < 0 && micros % 1000 != 0 ? 1 : 0);
  return TimeSample(
    interval: TimeInterval(
      startMs: floorMs(lowerMicros),
      endMs: -floorMs(-upperMicros),
    ),
    sourceId: sourceId,
    groupId: groupId,
    uptimeMs: uptimeMs,
    authLevel: NtsAuthLevel.verified,
  );
}
