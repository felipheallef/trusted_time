import 'package:flutter_test/flutter_test.dart';
import 'package:trusted_time/trusted_time.dart';

void main() {
  group('TrustAnchor Deserialization Safety (CRITICAL-6)', () {
    test('handles invalid NtsAuthLevel index gracefully', () {
      final json = {
        'networkUtcMs': 1000000,
        'uptimeMs': 50000,
        'wallMs': 1000000,
        'uncertaintyMs': 10,
        'authLevel': 999, // Out of bounds
        'confidence': 1,
        'syncTime': 1000000,
      };

      final anchor = TrustAnchor.fromJson(json);
      expect(anchor.authLevel, NtsAuthLevel.none);
    });

    test('handles invalid ConfidenceLevel index gracefully', () {
      final json = {
        'networkUtcMs': 1000000,
        'uptimeMs': 50000,
        'wallMs': 1000000,
        'uncertaintyMs': 10,
        'authLevel': 1,
        'confidence': -1, // Out of bounds
        'syncTime': 1000000,
      };

      final anchor = TrustAnchor.fromJson(json);
      expect(anchor.confidence, ConfidenceLevel.none);
      expect(anchor.bootId, isNull);
    });

    test('round-trips the boot identity', () {
      const anchor = TrustAnchor(
        networkUtcMs: 1000000,
        uptimeMs: 50000,
        bootId: 'boot-1',
        wallMs: 1000000,
        uncertaintyMs: 10,
      );

      expect(TrustAnchor.fromJson(anchor.toJson()).bootId, 'boot-1');
    });

    test('handles missing optional fields with safe defaults', () {
      final json = {
        'networkUtcMs': 1000000,
        'uptimeMs': 50000,
        'wallMs': 1000000,
        'uncertaintyMs': 10,
      };

      final anchor = TrustAnchor.fromJson(json);
      expect(anchor.authLevel, NtsAuthLevel.none);
      expect(anchor.confidence, ConfidenceLevel.none);
    });
  });

  group('TrustedTimeConfig NTS Trust Mode & Options', () {
    test(
      'defaults to platformWithFallback, null customRoots, and 5000ms timeout',
      () {
        const config = TrustedTimeConfig();
        expect(config.ntsTrustMode, TrustMode.platformWithFallback);
        expect(config.ntsCustomRoots, isNull);
        expect(config.ntsTimeoutMs, 5000);
      },
    );

    test('supports custom trustMode, customRoots, and ntsTimeoutMs', () {
      final customCert = [1, 2, 3, 4, 5];
      final config = TrustedTimeConfig(
        ntsTrustMode: TrustMode.custom,
        ntsCustomRoots: customCert,
        ntsTimeoutMs: 3000,
      );
      expect(config.ntsTrustMode, TrustMode.custom);
      expect(config.ntsCustomRoots, customCert);
      expect(config.ntsTimeoutMs, 3000);
    });

    test('supports bundledOnly trustMode', () {
      const config = TrustedTimeConfig(ntsTrustMode: TrustMode.bundledOnly);
      expect(config.ntsTrustMode, TrustMode.bundledOnly);
    });
  });
}
