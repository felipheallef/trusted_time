import '../domain/time_sample.dart';
import '../domain/time_source.dart';
import '../monotonic_clock.dart';

/// NTS time source stub — actual implementation in `nts_source.dart`.
final class NtsSource implements TimeSource {
  /// Documented.
  NtsSource(
    this._host, {
    int port = 4460,
    Object? trustMode,
    List<int>? customRoots,
    int timeoutMs = 5000,
    void Function(int)? onStratumObserved,
    MonotonicClock? clock,
    double oscillatorDriftFactor = 0.00005,
  });

  final String _host;

  @override
  String get id => 'nts:$_host';

  @override
  String get groupId => _host;

  @override
  Future<TimeSample> getTime() =>
      throw UnimplementedError('NTS requires dart:io');

  /// Releases source resources.
  void dispose() {}
}
