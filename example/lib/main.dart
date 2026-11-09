import 'package:flutter/material.dart';
import 'package:ssg_shell/ssg_shell.dart';

/// 壳的 A 面调试台：下发配置、开 IM、看事件、导诊断。
///
/// 真机上验收按 §12 走，这里只是把各条通道摆到一屏里，方便联调时逐条确认。
void main() {
  runApp(const DemoApp());
}

/// 换成自己的入口地址。§8.1 必须 HTTPS。
///
/// 现在先指向 google.com 只是为了有个真的能加载出来的页面：容器、UA、安全区、
/// 返回键、外链、兜底 reload 这些都能验。但它不是 IM Web，所以
/// §3.1 的十个事件、§1.3 的注入自检、§11.2 的 `eventWebAlive` 都不会有 ——
/// 那几项要换成真实入口地址才有意义。
const String kEntryUrl = 'https://web217-test-2.ssg18app.com/';
const String kChannelCode = 'ch001';

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ssg_shell',
        theme: ThemeData(colorSchemeSeed: const Color(0xFF2F6BFF), useMaterial3: true),
        home: const ShellConsole(),
      );
}

class ShellConsole extends StatefulWidget {
  const ShellConsole({super.key});

  @override
  State<ShellConsole> createState() => _ShellConsoleState();
}

class _ShellConsoleState extends State<ShellConsole> {
  final SsgShell _shell = SsgShell.instance;
  final List<String> _log = <String>[];

  ShellInfo? _info;
  KernelInfo? _kernel;
  bool _bSide = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _shell.webEvents.listen((event) {
      // §3.1 的十个事件。联调时原生日志里也应该能看到同样的十条（§12.2）。
      _append('web  ${event.rawName}  ${event.params}');
    });
    _shell.shellEvents.listen((event) {
      // §11.2 的 stallDetected / reloadIssued / webViewRecreated 都从这里出来。
      _append('shell ${event.type.name}  ${event.message ?? ''}');
    });
    _boot();
  }

  Future<void> _boot() async {
    try {
      final info = await _shell.initialize(
        const ShellConfig(entryUrl: kEntryUrl, channelCode: kChannelCode),
      );
      final kernel = await _shell.getKernelInfo();
      if (!mounted) return;
      setState(() {
        _info = info;
        _kernel = kernel;
      });
      // §11.7 内核过低一次性提示，允许忽略，不要阻断启动。
      if (kernel.verdict == KernelVerdict.belowMinimum) _warnKernel(kernel);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  void _warnKernel(KernelInfo kernel) {
    _append('内核 ${kernel.versionName} 低于下限，建议更新 Android System WebView（§11.7）');
  }

  void _append(String line) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, line);
      if (_log.length > 200) _log.removeLast();
    });
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Scaffold(
      appBar: AppBar(title: const Text('ssg_shell 调试台')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (_error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text('initialize 失败：$_error'),
              ),
            ),
          // §1.1 六个字段齐全才算注入有效；缺 bundleId 的设备收不到推送。
          _Section(
            title: '__SSG_SHELL__（§1.1）',
            children: <Widget>[
              _row('platform', info?.platform.name),
              _row('bundleId', info?.bundleId),
              _row('shellVersion', info?.shellVersion),
              _row('webviewVersion', info?.webviewVersion),
              _row('deviceModel', info?.deviceModel),
              _row('osVersion', info?.osVersion),
              _row('内核判定', _kernel?.verdict.name),
            ],
          ),
          _Section(
            title: '容器',
            children: <Widget>[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('B 面开关（§9.6）'),
                subtitle: const Text('开启后冷启动直接进 Web，原生会落盘这个值'),
                value: _bSide,
                onChanged: (value) async {
                  setState(() => _bSide = value);
                  await _shell.setBSideEnabled(value);
                },
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton(onPressed: _shell.openIm, child: const Text('打开 IM')),
                  OutlinedButton(onPressed: _shell.closeIm, child: const Text('关闭 IM')),
                  OutlinedButton(onPressed: _shell.preload, child: const Text('预加载')),
                  OutlinedButton(
                    onPressed: () async {
                      final ok = await _shell.verifyInjection();
                      _append('注入自检（§1.3）：is-web-browser=${!ok} → ${ok ? "通过" : "未生效"}');
                    },
                    child: const Text('注入自检'),
                  ),
                ],
              ),
            ],
          ),
          _Section(
            title: '推送与深链（§5）',
            children: <Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  OutlinedButton(
                    onPressed: () async {
                      // 真实接法：OneSignal 的前台收到回调里把 additionalData 原样传进来。
                      final decision = await _shell.handlePushReceived(
                        const <String, Object?>{'chat_id': '1571275627', 'msg_id': '8842'},
                      );
                      _append(
                        '推送到达 → 抑制通知=${decision.suppressNotification} '
                        '捅醒=${decision.nudgedWeb}（${decision.reason}）',
                      );
                    },
                    child: const Text('模拟推送到达'),
                  ),
                  OutlinedButton(
                    onPressed: () => _shell.handlePushOpened(
                      const <String, Object?>{'chat_id': '1571275627', 'msg_id': '8842'},
                    ),
                    child: const Text('模拟点击通知'),
                  ),
                ],
              ),
            ],
          ),
          _Section(
            title: '假死防护（§11）',
            children: <Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  OutlinedButton(onPressed: _shell.reloadWeb, child: const Text('兜底 reload')),
                  OutlinedButton(
                    onPressed: _shell.recreateWebView,
                    child: const Text('重建 WebView'),
                  ),
                  OutlinedButton(
                    onPressed: () => _shell.nudgeNetwork(NetworkType.wifi),
                    child: const Text('onNetwork(wifi)'),
                  ),
                  OutlinedButton(onPressed: _showDiagnostics, child: const Text('诊断导出')),
                ],
              ),
            ],
          ),
          _Section(
            title: '事件流',
            children: <Widget>[
              if (_log.isEmpty)
                const Text('等待事件…', style: TextStyle(color: Colors.black54))
              else
                for (final line in _log)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(line, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                  ),
            ],
          ),
        ],
      ),
    );
  }

  /// §11.6 隐藏入口：能查看并导出 URL / UA / 内核版本 / `__SSG_SHELL__` / 最近 console。
  Future<void> _showDiagnostics() async {
    final text = await _shell.exportDiagnostics();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('诊断（§11.6）'),
        content: SingleChildScrollView(
          child: SelectableText(text, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ],
      ),
    );
  }

  Widget _row(String name, String? value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(width: 120, child: Text(name, style: const TextStyle(color: Colors.black54))),
            Expanded(child: Text(value?.isNotEmpty == true ? value! : '—')),
          ],
        ),
      );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(title, style: Theme.of(context).textTheme.titleMedium),
              ),
              ...children,
            ],
          ),
        ),
      );
}
