import 'package:flutter_test/flutter_test.dart';
// Tests need to replace the bridge layer; HostApi and the DTOs are not in the public exports.
import 'package:ssg_shell/src/messages.g.dart'
    show ShellConfigDto, SsgShellHostApi;
import 'package:ssg_shell/ssg_shell.dart';

/// Replaces the bridge layer. Implements only the methods `initialize()` reaches.
class _FakeHost extends SsgShellHostApi {
  bool persistedBSide = false;
  int isBSideEnabledCalls = 0;
  ShellConfigDto? received;

  /// Simulates native code replaying, before `initialize` returns, the events Dart missed before coming online.
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

  group('§9.6 B side switch', () {
    test(
      'when omitted, keeps the natively persisted value instead of overwriting it with the default',
      () async {
        final host = _FakeHost()..persistedBSide = true;
        final shell = SsgShell.withHost(host);

        await shell.initialize(
          const ShellConfig(entryUrl: url),
          requestNotificationAfterLogin: false,
        );

        expect(host.received!.bSideEnabled, isTrue);
      },
    );

    test('is off when never set', () async {
      final host = _FakeHost();
      final shell = SsgShell.withHost(host);

      await shell.initialize(
        const ShellConfig(entryUrl: url),
        requestNotificationAfterLogin: false,
      );

      expect(host.received!.bSideEnabled, isFalse);
    });

    test(
      'an explicit value takes precedence and the persisted one is not read',
      () async {
        final host = _FakeHost()..persistedBSide = true;
        final shell = SsgShell.withHost(host);

        await shell.initialize(
          const ShellConfig(entryUrl: url, bSideEnabled: false),
          requestNotificationAfterLogin: false,
        );

        expect(host.received!.bSideEnabled, isFalse);
        expect(host.isBSideEnabledCalls, 0);
      },
    );
  });

  group('events missed before Dart comes online', () {
    test(
      'login replayed during initialize reaches a listener attached right after await',
      () async {
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
        // State does not wait for events to be released; it is already correct when initialize returns.
        expect(shell.isLoggedIn, isTrue);
        expect(shell.uid, '1571277787');
      },
    );

    test(
      'a listener attached before the call also receives it only once',
      () async {
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
      },
    );

    test(
      'events after initialize are forwarded in real time as usual',
      () async {
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
      },
    );
  });
}
