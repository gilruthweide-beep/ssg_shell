// 在真机 / 模拟器上跑，验证过线的那一层真的通了（Dart 单测只能验 Dart 侧）。
//
//   cd example && flutter test integration_test
//
// §12 的验收项大多要人肉操作（点附件、切后台、断网），这里只覆盖「不需要 Web 配合」
// 的那几条：initialize 的六个字段、内核判定、诊断导出。

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ssg_shell/ssg_shell.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 不联真实入口地址：这几条都不需要页面加载完成。
  const ShellConfig config = ShellConfig(
    entryUrl: 'https://www.google.com/',
    channelCode: 'ch001',
  );

  testWidgets('§1.1 initialize 返回的六个字段齐全', (WidgetTester tester) async {
    final ShellInfo info = await SsgShell.instance.initialize(
      config,
      // 测试里不要让它自己去申请通知权限（§6.2 的时机由宿主控制），也不预加载。
      requestNotificationAfterLogin: false,
      autoPreload: false,
    );

    expect(info.bundleId, isNotEmpty, reason: '缺 bundleId 的设备收不到推送（§1.1）');
    expect(info.shellVersion, isNotEmpty);
    expect(info.deviceModel, isNotEmpty, reason: '§11.5 诊断字段，按机型定位假死');
    expect(info.osVersion, isNotEmpty);
    expect(
      info.platform,
      anyOf(ShellPlatform.android, ShellPlatform.ios),
      reason: '§1.1 platform 只接受 android / ios',
    );
  });

  testWidgets('§8.1 / §11.7 内核版本能读到', (WidgetTester tester) async {
    final KernelInfo kernel = await SsgShell.instance.getKernelInfo();
    // iOS 读 WebKit 版本，Android 读 WebView 实现包；取不到时 majorVersion 为 -1。
    expect(kernel.verdict, isNot(KernelVerdict.belowMinimum), reason: '§8.1 内核下限 92');
  });

  testWidgets('§11.6 诊断能导出', (WidgetTester tester) async {
    await SsgShell.instance.initialize(
      config,
      requestNotificationAfterLogin: false,
      autoPreload: false,
    );
    final String text = await SsgShell.instance.exportDiagnostics();
    expect(text, contains('SSG Shell'));
    expect(text, contains('UA'));
  });
}
