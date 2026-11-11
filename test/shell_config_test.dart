import 'package:flutter_test/flutter_test.dart';
import 'package:ssg_shell/ssg_shell.dart';

void main() {
  group('ShellConfig defaults match the specification', () {
    const ShellConfig config = ShellConfig(entryUrl: 'https://im.example.com/');

    test(
      '§11.1 heartbeat 20s, §11.2 timeout 60s, §11.2.3 confirmation 10s',
      () {
        final dto = config.toDto();
        expect(dto.heartbeatIntervalMs, 20000);
        expect(dto.aliveTimeoutMs, 60000);
        expect(dto.reloadConfirmTimeoutMs, 10000);
      },
    );

    test('§11.2.5 recovery backoff 180s / 600s', () {
      final dto = config.toDto();
      expect(dto.recoveryBackoffFirstMs, 180000);
      expect(dto.recoveryBackoffLaterMs, 600000);
    });

    test('§9.6 splash limit 30s and §10.4 debounce within 1–2s', () {
      final dto = config.toDto();
      expect(dto.splashTimeoutMs, 30000);
      expect(dto.networkDebounceMs, inInclusiveRange(1000, 2000));
    });

    test('§8.1 engine minimum 92 / recommended 110, §9.4 white background', () {
      final dto = config.toDto();
      expect(dto.minKernelVersion, 92);
      expect(dto.recommendedKernelVersion, 110);
      expect(dto.backgroundColorArgb, 0xFFFFFFFF);
    });

    test(
      '§5.4 foreground suppression and badge management enabled by default',
      () {
        final dto = config.toDto();
        expect(dto.suppressForegroundNotifications, isTrue);
        expect(dto.manageBadge, isTrue);
      },
    );
  });

  group('§2.1 complete landing URL is passed to native unchanged', () {
    test(
      'preserves parameter casing, encoding, repeated parameters, and fragment',
      () {
        const String url =
            'https://im.example.com/?ChannelCode=from%2Fweb'
            '&tag=a+%20b&tag=%2526#/chat?channelcode=fragment';
        const ShellConfig config = ShellConfig(entryUrl: url);

        expect(config.toDto().entryUrl, url);
        expect(config.toDto().channelCode, isEmpty);
      },
    );

    test(
      'legacy channelCode is ignored and URLs without a channel remain valid',
      () {
        const ShellConfig config = ShellConfig(
          entryUrl: 'https://im.example.com/?a=1#home',
          // ignore: deprecated_member_use_from_same_package
          channelCode: 'ChannelCode_google',
        );

        expect(config.toDto().entryUrl, 'https://im.example.com/?a=1#home');
        expect(config.toDto().channelCode, isEmpty);
      },
    );
  });

  group('§8.1 HTTPS validation', () {
    test('https passes', () {
      expect(
        const ShellConfig(entryUrl: 'https://im.example.com/').isSecureEntry,
        isTrue,
      );
    });

    test('nonlocal http fails', () {
      expect(
        const ShellConfig(entryUrl: 'http://im.example.com/').isSecureEntry,
        isFalse,
      );
    });

    test('local development URLs pass', () {
      expect(
        const ShellConfig(entryUrl: 'http://localhost:8080/').isSecureEntry,
        isTrue,
      );
      expect(
        const ShellConfig(entryUrl: 'http://10.0.2.2:8080/').isSecureEntry,
        isTrue,
      );
    });
  });

  test('copyWith changes only specified fields', () {
    const ShellConfig base = ShellConfig(entryUrl: 'https://a.example.com/');
    final ShellConfig next = base.copyWith(
      entryUrl: 'https://a.example.com/?channelcode=ch009',
      bSideEnabled: false,
    );

    expect(next.entryUrl, 'https://a.example.com/?channelcode=ch009');
    expect(next.bSideEnabled, isFalse);
    expect(next.heartbeatInterval, base.heartbeatInterval);
  });
}
