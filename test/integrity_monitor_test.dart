import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/integrity_monitor.dart';
import 'package:trusted_time/src/models.dart';
import 'package:trusted_time/src/monotonic_clock.dart';

class FakeMonotonicClock implements BootIdentityClock {
  int value = 1000;
  String? currentBootId = 'boot-1';
  @override
  Future<String?> bootId() async => currentBootId;
  @override
  Future<int> uptimeMs() async => value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // EventChannel uses MethodChannel under the hood for listen/cancel.
  // In test mode we mock the underlying MethodChannel so that calling
  // attach() (which calls receiveBroadcastStream()) doesn't throw
  // MissingPluginException. This does NOT simulate native event delivery
  // — it only allows the Dart-side logic to be tested in isolation.
  const integrityChannel = MethodChannel('trusted_time/integrity');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(integrityChannel, (call) async => null);

  group('IntegrityMonitor', () {
    late FakeMonotonicClock clock;
    late IntegrityMonitor monitor;

    setUp(() {
      clock = FakeMonotonicClock();
      monitor = IntegrityMonitor(clock: clock);
    });

    tearDown(() => monitor.dispose());

    test(
      'checkRebootOnWarmStart detects reboot when uptime < anchor',
      () async {
        clock.value = 500;
        final anchor = TrustAnchor(
          networkUtcMs: DateTime.now().millisecondsSinceEpoch,
          uptimeMs: 10000,
          wallMs: DateTime.now().millisecondsSinceEpoch,
          uncertaintyMs: 10,
        );
        final rebooted = await monitor.checkRebootOnWarmStart(anchor);
        expect(rebooted, isTrue);
      },
    );

    test(
      'checkRebootOnWarmStart accepts matching boot identity and uptime',
      () async {
        clock.value = 20000;
        final anchor = TrustAnchor(
          networkUtcMs: DateTime.now().millisecondsSinceEpoch,
          uptimeMs: 10000,
          bootId: 'boot-1',
          wallMs: DateTime.now().millisecondsSinceEpoch,
          uncertaintyMs: 10,
        );
        final rebooted = await monitor.checkRebootOnWarmStart(anchor);
        expect(rebooted, isFalse);
      },
    );

    test(
      'rejects a different boot even when uptime exceeds the anchor',
      () async {
        clock.value = 20000;
        clock.currentBootId = 'boot-2';
        const anchor = TrustAnchor(
          networkUtcMs: 1000000,
          uptimeMs: 10000,
          bootId: 'boot-1',
          wallMs: 1000000,
          uncertaintyMs: 10,
        );

        expect(await monitor.checkRebootOnWarmStart(anchor), isTrue);
      },
    );

    test('rejects matching boot identity if uptime moved backwards', () async {
      clock.value = 500;
      const anchor = TrustAnchor(
        networkUtcMs: 1000000,
        uptimeMs: 10000,
        bootId: 'boot-1',
        wallMs: 1000000,
        uncertaintyMs: 10,
      );

      expect(await monitor.checkRebootOnWarmStart(anchor), isTrue);
    });

    test('rejects legacy anchors without boot identity', () async {
      clock.value = 20000;
      const anchor = TrustAnchor(
        networkUtcMs: 1000000,
        uptimeMs: 10000,
        wallMs: 1000000,
        uncertaintyMs: 10,
      );

      expect(await monitor.checkRebootOnWarmStart(anchor), isTrue);
    });

    test('rejects restoration when boot identity is unavailable', () async {
      clock.currentBootId = null;
      const anchor = TrustAnchor(
        networkUtcMs: 1000000,
        uptimeMs: 1000,
        bootId: 'boot-1',
        wallMs: 1000000,
        uncertaintyMs: 10,
      );

      expect(await monitor.checkRebootOnWarmStart(anchor), isTrue);
    });

    test('events stream is a broadcast stream', () {
      expect(monitor.events.isBroadcast, isTrue);
    });

    test('attach establishes monitoring without throwing', () {
      final anchor = TrustAnchor(
        networkUtcMs: DateTime.now().millisecondsSinceEpoch,
        uptimeMs: 1000,
        wallMs: DateTime.now().millisecondsSinceEpoch,
        uncertaintyMs: 10,
      );
      expect(() => monitor.attach(anchor), returnsNormally);
    });

    test('multiple attaches cancel previous subscription', () {
      final anchor = TrustAnchor(
        networkUtcMs: DateTime.now().millisecondsSinceEpoch,
        uptimeMs: 1000,
        wallMs: DateTime.now().millisecondsSinceEpoch,
        uncertaintyMs: 10,
      );
      expect(() {
        monitor.attach(anchor);
        monitor.attach(anchor);
      }, returnsNormally);
    });

    test('dispose can be called multiple times safely', () {
      monitor.dispose();
      expect(() => monitor.dispose(), returnsNormally);
    });
  });
}
