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
    final ShellConfig next = base.copyWith(channelCode: 'ch009', bSideEnabled: false);

    expect(next.entryUrl, base.entryUrl);
    expect(next.channelCode, 'ch009');
    expect(next.bSideEnabled, isFalse);
    expect(next.heartbeatInterval, base.heartbeatInterval);
  });
}
