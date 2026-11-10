import 'package:flutter_test/flutter_test.dart';
import 'package:ssg_shell/ssg_shell.dart';

void main() {
  group('ShellConfig 默认值 = 规范值', () {
    const ShellConfig config = ShellConfig(entryUrl: 'https://im.example.com/');

    test('§11.1 心跳 20 秒、§11.2 判定 60 秒、§11.2.3 确认 10 秒', () {
      final dto = config.toDto();
      expect(dto.heartbeatIntervalMs, 20000);
      expect(dto.aliveTimeoutMs, 60000);
      expect(dto.reloadConfirmTimeoutMs, 10000);
    });

    test('§11.2.5 退避 180 秒 / 600 秒', () {
      final dto = config.toDto();
      expect(dto.recoveryBackoffFirstMs, 180000);
      expect(dto.recoveryBackoffLaterMs, 600000);
    });

    test('§9.6 splash 上限 30 秒，§10.4 去抖落在 1~2 秒', () {
      final dto = config.toDto();
      expect(dto.splashTimeoutMs, 30000);
      expect(dto.networkDebounceMs, inInclusiveRange(1000, 2000));
    });

    test('§8.1 内核下限 92 / 推荐 110，§9.4 背景白色', () {
      final dto = config.toDto();
      expect(dto.minKernelVersion, 92);
      expect(dto.recommendedKernelVersion, 110);
      expect(dto.backgroundColorArgb, 0xFFFFFFFF);
    });

    test('§5.4 前台抑制与角标默认开', () {
      final dto = config.toDto();
      expect(dto.suppressForegroundNotifications, isTrue);
      expect(dto.manageBadge, isTrue);
    });
  });

  group('§2.1 完整落地 URL 原样传给原生', () {
    test('保留参数大小写、编码、重复参数和 fragment', () {
      const String url = 'https://im.example.com/?ChannelCode=from%2Fweb'
          '&tag=a+%20b&tag=%2526#/chat?channelcode=fragment';
      const ShellConfig config = ShellConfig(entryUrl: url);

      expect(config.toDto().entryUrl, url);
      expect(config.toDto().channelCode, isEmpty);
    });

    test('旧版 channelCode 入参不再下发，URL 不带渠道码也有效', () {
      const ShellConfig config = ShellConfig(
        entryUrl: 'https://im.example.com/?a=1#home',
        // ignore: deprecated_member_use_from_same_package
        channelCode: 'ChannelCode_google',
      );

      expect(config.toDto().entryUrl, 'https://im.example.com/?a=1#home');
      expect(config.toDto().channelCode, isEmpty);
    });
  });

  group('§8.1 HTTPS 自检', () {
    test('https 通过', () {
      expect(const ShellConfig(entryUrl: 'https://im.example.com/').isSecureEntry, isTrue);
    });

    test('普通 http 不通过', () {
      expect(const ShellConfig(entryUrl: 'http://im.example.com/').isSecureEntry, isFalse);
    });

    test('本地调试地址放行', () {
      expect(const ShellConfig(entryUrl: 'http://localhost:8080/').isSecureEntry, isTrue);
      expect(const ShellConfig(entryUrl: 'http://10.0.2.2:8080/').isSecureEntry, isTrue);
    });
  });

  test('copyWith 只改指定字段', () {
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
