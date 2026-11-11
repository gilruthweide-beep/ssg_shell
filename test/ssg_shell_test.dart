import 'package:flutter_test/flutter_test.dart';
// 测试要顶替过线的那一层，HostApi 和 DTO 不在对外导出的名单里。
import 'package:ssg_shell/src/messages.g.dart' show ShellConfigDto, SsgShellHostApi;
import 'package:ssg_shell/ssg_shell.dart';

/// 顶替过线的那一层。只实现 `initialize()` 会走到的几个方法。
class _FakeHost extends SsgShellHostApi {
  bool persistedBSide = false;
  int isBSideEnabledCalls = 0;
  ShellConfigDto? received;

  /// 模拟原生在 `initialize` 返回之前补发 Dart 上线前错过的事件。
  void Function()? duringInitialize;

  @override
  Future<bool> isBSideEnabled() async {
    isBSideEnabledCalls += 1;
    return persistedBSide;
  }

  @override
  Future<ShellInfo> initialize(ShellConfigDto config) async {
    received = config;
    duringInitialize?.call();
    return ShellInfo(
      platform: ShellPlatform.android,
      bundleId: 'com.example.app',
      shellVersion: '1.0.2',
      webviewVersion: '120.0.0.0',
      deviceModel: 'Pixel',
      osVersion: '14',
    );
  }

  @override
  Future<void> preload() async {}
}

WebEvent _login(String uid) => WebEvent(
      name: WebEventName.login,
      rawName: 'login',
      receivedAtMs: 0,
      params: <String, String>{'uid': uid},
      uid: uid,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String url = 'https://im.example.com/';

  group('§9.6 B 面开关', () {
    test('不传时沿用原生落盘的值，不拿默认值覆盖', () async {
      final host = _FakeHost()..persistedBSide = true;
      final shell = SsgShell.withHost(host);

      await shell.initialize(
        const ShellConfig(entryUrl: url),
        requestNotificationAfterLogin: false,
      );

      expect(host.received!.bSideEnabled, isTrue);
    });

    test('从没设过时是关', () async {
      final host = _FakeHost();
      final shell = SsgShell.withHost(host);

      await shell.initialize(
        const ShellConfig(entryUrl: url),
        requestNotificationAfterLogin: false,
      );

      expect(host.received!.bSideEnabled, isFalse);
    });

    test('显式传值时以这次为准，不去读落盘的那份', () async {
      final host = _FakeHost()..persistedBSide = true;
      final shell = SsgShell.withHost(host);

      await shell.initialize(
        const ShellConfig(entryUrl: url, bSideEnabled: false),
        requestNotificationAfterLogin: false,
      );

      expect(host.received!.bSideEnabled, isFalse);
      expect(host.isBSideEnabledCalls, 0);
    });
  });

  group('Dart 上线前错过的事件', () {
    test('initialize 期间补发的 login，紧跟在 await 后面挂的监听能收到', () async {
      final host = _FakeHost();
      final shell = SsgShell.withHost(host);
      host.duringInitialize = () => shell.onWebEvent(_login('1571277787'));

      await shell.initialize(
        const ShellConfig(entryUrl: url),
        requestNotificationAfterLogin: false,
      );
      final received = <String?>[];
      shell.on(WebEventName.login).listen((event) => received.add(event.uid));

      await pumpEventQueue();

      expect(received, <String?>['1571277787']);
      // 状态不等事件放出来，initialize 返回时就已经是对的。
      expect(shell.isLoggedIn, isTrue);
      expect(shell.uid, '1571277787');
    });

    test('调用之前就挂好的监听同样只收到一次', () async {
      final host = _FakeHost();
      final shell = SsgShell.withHost(host);
      host.duringInitialize = () => shell.onWebEvent(_login('42'));
      final received = <String?>[];
      shell.on(WebEventName.login).listen((event) => received.add(event.uid));

      await shell.initialize(
        const ShellConfig(entryUrl: url),
        requestNotificationAfterLogin: false,
      );
      await pumpEventQueue();

      expect(received, <String?>['42']);
    });

    test('initialize 之后的事件照常实时转发', () async {
      final host = _FakeHost();
      final shell = SsgShell.withHost(host);
      await shell.initialize(
        const ShellConfig(entryUrl: url),
        requestNotificationAfterLogin: false,
      );
      final received = <String?>[];
      shell.on(WebEventName.login).listen((event) => received.add(event.uid));

      shell.onWebEvent(_login('7'));
      await pumpEventQueue();

      expect(received, <String?>['7']);
    });
  });
}
