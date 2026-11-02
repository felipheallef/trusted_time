import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/src/monotonic_clock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('trusted_time/monotonic');

  group('PlatformMonotonicClock', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
            if (methodCall.method == 'getUptimeMs') return 42000;
            if (methodCall.method == 'getBootId') return 'boot-1';
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('uptimeMs returns value from platform channel', () async {
      final clock = PlatformMonotonicClock();
      final result = await clock.uptimeMs();
      expect(result, 42000);
    });

    test('bootId returns the platform boot identity', () async {
      expect(await PlatformMonotonicClock().bootId(), 'boot-1');
    });

    test('bootId returns null for missing platform support', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      expect(await PlatformMonotonicClock().bootId(), isNull);
    });

    test('bootId returns null when platform access is denied', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'ACCESS_DENIED');
          });

      expect(await PlatformMonotonicClock().bootId(), isNull);
    });

    test('bootId returns null for an empty identity', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => '  ');

      expect(await PlatformMonotonicClock().bootId(), isNull);
    });

    test('uptimeMs throws when platform returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async => null);

      final clock = PlatformMonotonicClock();
      expect(() => clock.uptimeMs(), throwsA(isA<StateError>()));
    });
  });
}
