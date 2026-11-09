// 调试台自己的 widget 测试。壳的行为在原生侧，这里只确认 A 面能起起来，
// 以及 initialize 失败（没有原生实现的测试环境里必然失败）时不会白屏。

import 'package:flutter_test/flutter_test.dart';
import 'package:ssg_shell_example/main.dart';

void main() {
  testWidgets('调试台能渲染出各个分区', (WidgetTester tester) async {
    await tester.pumpWidget(const DemoApp());
    await tester.pump();

    expect(find.text('ssg_shell 调试台'), findsOneWidget);
    expect(find.text('打开 IM'), findsOneWidget);
    expect(find.textContaining('__SSG_SHELL__'), findsOneWidget);
  });
}
