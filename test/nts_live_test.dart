import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts;
import 'package:trusted_time/src/monotonic_clock.dart';
import 'package:trusted_time/src/sources/nts_source.dart';
import 'package:trusted_time/src/sync_engine.dart';
import 'package:trusted_time/trusted_time.dart';

class _SmokeClock implements MonotonicClock {
  final Stopwatch elapsed = Stopwatch()..start();

  @override
  Future<int> uptimeMs() async => elapsed.elapsedMilliseconds;
}

void main() {
  test(
    'native NTS providers establish authenticated, aligned consensus',
    () async {
      const libraryPath = String.fromEnvironment('NTS_NATIVE_LIBRARY');
      if (libraryPath.isEmpty || !File(libraryPath).isAbsolute) {
        throw ArgumentError(
          'NTS_NATIVE_LIBRARY must be a trusted absolute path.',
        );
      }
      await nts.NtsBridge.ensureInitialized(
        externalLibrary: ExternalLibrary.open(libraryPath),
      );
      final clock = _SmokeClock();
      final engine = SyncEngine(
        config: TrustedTimeConfig(
          ntpServers: [],
          ntsServers: [],
          httpsSources: [],
          additionalSources: [
            for (final host in [
              'a.st1.ntp.br',
              'time.cloudflare.com',
              'nts.netnod.se',
            ])
              NtsSource(host, clock: clock),
          ],
          maxLatency: const Duration(seconds: 8),
          earlyExit: false,
          enableDiagnostics: true,
        ),
        clock: clock,
      );
      addTearDown(engine.dispose);
      final anchor = await engine.sync();
      expect(anchor.authLevel, NtsAuthLevel.verified);
      expect(anchor.uncertaintyMs, lessThanOrEqualTo(5000));
    },
    skip: !const bool.fromEnvironment('TRUSTED_TIME_LIVE_NTS'),
  );
}
