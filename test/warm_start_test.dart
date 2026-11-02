import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/domain/time_interval.dart';
import 'package:trusted_time/src/domain/time_sample.dart';
import 'package:trusted_time/src/domain/time_source.dart';
import 'package:trusted_time/src/exceptions.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/trusted_time_impl.dart';

class FixedTimeSource implements TimeSource {
  FixedTimeSource(this.id, this.utcMs);

  @override
  final String id;
  final int utcMs;

  @override
  String get groupId => id;

  @override
  Future<TimeSample> getTime() async => TimeSample(
    interval: TimeInterval(startMs: utcMs - 10, endMs: utcMs + 10),
    sourceId: id,
    groupId: groupId,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const storageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const monotonicChannel = MethodChannel('trusted_time/monotonic');
  const backgroundChannel = MethodChannel('trusted_time/background');
  const integrityChannel = MethodChannel('trusted_time/integrity');
  const offlineConfig = TrustedTimeConfig(
    ntpServers: [],
    ntsServers: [],
    httpsSources: [],
  );
  const savedUtcMs = 1800000000000;
  const savedUptimeMs = 10000;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Map<String, String> storage;
  late int currentUptimeMs;
  String? currentBootId;
  TrustedTimeImpl? implementation;

  void seedAnchor({String? bootId = 'boot-1', int wallMs = savedUtcMs}) {
    storage['tt_anchor_v2'] = jsonEncode(
      TrustAnchor(
        networkUtcMs: savedUtcMs,
        uptimeMs: savedUptimeMs,
        bootId: bootId,
        wallMs: wallMs,
        uncertaintyMs: 10,
      ).toJson(),
    );
  }

  setUp(() {
    storage = {};
    currentUptimeMs = savedUptimeMs + const Duration(hours: 1).inMilliseconds;
    currentBootId = 'boot-1';
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      final arguments = call.arguments as Map<dynamic, dynamic>;
      final key = arguments['key'] as String;
      switch (call.method) {
        case 'read':
          return storage[key];
        case 'write':
          storage[key] = arguments['value'] as String;
        case 'delete':
          storage.remove(key);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(monotonicChannel, (call) async {
      return switch (call.method) {
        'getUptimeMs' => currentUptimeMs,
        'getBootId' => currentBootId,
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(backgroundChannel, (call) async => null);
    messenger.setMockMethodCallHandler(integrityChannel, (call) async => null);
  });

  tearDown(() async {
    implementation?.dispose();
    implementation = null;
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'warm start projects a saved anchor using elapsed hardware uptime',
    () async {
      seedAnchor();

      implementation = await TrustedTimeImpl.init(offlineConfig);

      expect(implementation!.isTrusted, isTrue);
      expect(
        implementation!.now().millisecondsSinceEpoch,
        inInclusiveRange(savedUtcMs + 3600000, savedUtcMs + 3601000),
      );
    },
  );

  test(
    'restoration does not derive elapsed time from the system wall clock',
    () async {
      seedAnchor(wallMs: 1);

      implementation = await TrustedTimeImpl.init(offlineConfig);

      expect(implementation!.isTrusted, isTrue);
      expect(
        implementation!.now().millisecondsSinceEpoch,
        inInclusiveRange(savedUtcMs + 3600000, savedUtcMs + 3601000),
      );
    },
  );

  test('a reboot with larger uptime cannot restore trust offline', () async {
    seedAnchor();
    currentBootId = 'boot-2';

    implementation = await TrustedTimeImpl.init(offlineConfig);

    expect(implementation!.isTrusted, isFalse);
    expect(implementation!.now, throwsA(isA<TrustedTimeNotReadyException>()));
  });

  test(
    'a backwards uptime cannot restore trust even with matching boot ID',
    () async {
      seedAnchor();
      currentUptimeMs = savedUptimeMs - 1;

      implementation = await TrustedTimeImpl.init(offlineConfig);

      expect(implementation!.isTrusted, isFalse);
    },
  );

  test('legacy anchors require a new network sync', () async {
    seedAnchor(bootId: null);
    final persisted =
        jsonDecode(storage['tt_anchor_v2']!) as Map<String, dynamic>;
    persisted.remove('bootId');
    storage['tt_anchor_v2'] = jsonEncode(persisted);

    implementation = await TrustedTimeImpl.init(offlineConfig);

    expect(implementation!.isTrusted, isFalse);
  });

  test('unavailable boot identity cannot restore trust offline', () async {
    seedAnchor();
    currentBootId = null;

    implementation = await TrustedTimeImpl.init(offlineConfig);

    expect(implementation!.isTrusted, isFalse);
  });

  test(
    'a fresh network anchor persists boot identity and survives restart',
    () async {
      currentUptimeMs = savedUptimeMs;
      implementation = await TrustedTimeImpl.init(
        TrustedTimeConfig(
          ntpServers: [],
          ntsServers: [],
          httpsSources: [],
          additionalSources: [
            FixedTimeSource('provider-1', savedUtcMs),
            FixedTimeSource('provider-2', savedUtcMs),
          ],
        ),
      );
      expect(implementation!.isTrusted, isTrue);
      final persisted =
          jsonDecode(storage['tt_anchor_v2']!) as Map<String, dynamic>;
      expect(persisted['bootId'], 'boot-1');

      currentUptimeMs += const Duration(hours: 1).inMilliseconds;
      implementation = await TrustedTimeImpl.init(offlineConfig);

      expect(implementation!.isTrusted, isTrue);
      expect(
        implementation!.now().millisecondsSinceEpoch,
        inInclusiveRange(savedUtcMs + 3600000, savedUtcMs + 3601000),
      );
    },
  );

  test(
    'network sync works without boot identity but cannot be restored',
    () async {
      currentBootId = null;
      implementation = await TrustedTimeImpl.init(
        TrustedTimeConfig(
          ntpServers: [],
          ntsServers: [],
          httpsSources: [],
          additionalSources: [
            FixedTimeSource('provider-1', savedUtcMs),
            FixedTimeSource('provider-2', savedUtcMs),
          ],
        ),
      );
      expect(implementation!.isTrusted, isTrue);

      implementation = await TrustedTimeImpl.init(offlineConfig);

      expect(implementation!.isTrusted, isFalse);
    },
  );
}
