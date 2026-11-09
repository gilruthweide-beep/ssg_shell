import Foundation
import UIKit
import WebKit

/// §1.1 / §1.2 / §2.2 / §7.3 / §11.6：所有注入进页面的东西都在这里。
enum ShellInjection {

  // ------------------------------------------------------- message handler 名

  /// §3.2 十个 handler 全部注册，未注册的会抛异常，Web 已捕获但事件会丢。
  static let eventHandlers = [
    "eventWebReady", "eventRegister", "eventLogin", "eventLogout",
    "eventMessageSent", "eventWebAlive",
    "eventChatOpen", "eventChatClose", "eventChatRead", "eventUnreadCount",
  ]

  /// §11.6 console 转发。WKWebView 没有 `onConsoleMessage`，只能注入钩子。
  static let consoleHandler = "shellConsole"
  /// §7.3.1 文件输入框被拦下来之后通知原生。
  static let filePickHandler = "shellFilePick"
  /// §7.3.4 页面分块来拉文件内容（`WKScriptMessageHandlerWithReply`）。
  static let fileChunkHandler = "shellFileChunk"

  // -------------------------------------------------------------- §1.1 字段

  /// §1.1 六个必填字段。缺 `platform` 视为注入无效，缺 `bundleId` 收不到推送。
  static func shellInfo(shellVersion: String) -> ShellInfo {
    ShellInfo(
      platform: .ios,
      bundleId: Bundle.main.bundleIdentifier ?? "",
      shellVersion: shellVersion,
      webviewVersion: webKitVersion(),
      // §11.5 机型用原始标识符（iPhone15,2）：假死集中在特定机型上，
      // 营销名反而对不上号。
      deviceModel: deviceModel(),
      osVersion: UIDevice.current.systemVersion
    )
  }

  static func deviceModel() -> String {
    var info = utsname()
    uname(&info)
    let raw = withUnsafePointer(to: &info.machine) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
    return raw.isEmpty ? "iOS" : raw
  }

  /// WebKit 随系统升级，不能单独更新，所以这个值只进诊断埋点（§1.1 / §11.5）。
  static func webKitVersion() -> String {
    let bundle = Bundle(identifier: "com.apple.WebKit")
      ?? Bundle(path: "/System/Library/Frameworks/WebKit.framework")
    let info = bundle?.infoDictionary
    if let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty { return short }
    if let build = info?["CFBundleVersion"] as? String, !build.isEmpty { return build }
    return ""
  }

  /// §2.2 UA：`config.applicationNameForUserAgent`，WebKit 会把它**追加**在默认 UA 后面。
  ///
  /// 不要整段替换 `customUserAgent` —— Web 与服务端都有按 UA 判平台的逻辑
  /// （`Android`、`iPhone`、`iPad`），替换会让平台识别全面失效。
  static func applicationNameForUserAgent(shellVersion: String) -> String {
    "SSGShell/\(shellVersion) iOS"
  }

  // -------------------------------------------------------------- §1.2 注入

  /// §1.2 必须在页面任何脚本执行之前完成：Web 侧有一组常量在模块加载那一刻求值
  /// （容器判定、重连参数、装机卡片开关），晚于首个 bundle 即无效。
  static func injectionScript(_ info: ShellInfo) -> String {
    let fields = [
      "platform:'\(escape("ios"))'",
      "bundleId:'\(escape(info.bundleId))'",
      "shellVersion:'\(escape(info.shellVersion))'",
      "webviewVersion:'\(escape(info.webviewVersion))'",
      "deviceModel:'\(escape(info.deviceModel))'",
      "osVersion:'\(escape(info.osVersion))'",
    ].joined(separator: ",")
    return "window.__SSG_SHELL__={\(fields)};"
  }

  private static func escape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "\\'")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "<", with: "\\u003c")
  }

  // ------------------------------------------------------- §11.6 console 转发

  /// 包一层 console，原实现照常调用。
  ///
  /// §9.6：注入调试工具时不要覆盖 `window` 上的现有字段 —— 这里只加
  /// `__ssgConsoleHooked` 一个标记，`__ssgShell` 和业务字段一个都不碰。
  static let consoleScript = """
  (function () {
    if (window.__ssgConsoleHooked) { return; }
    window.__ssgConsoleHooked = true;
    var LIMIT = 4000;
    function text(args) {
      var out = [];
      for (var i = 0; i < args.length; i++) {
        var a = args[i];
        try {
          if (a instanceof Error) {
            out.push(a.name + ': ' + a.message + (a.stack ? '\\n' + a.stack : ''));
          } else if (a !== null && typeof a === 'object') {
            out.push(JSON.stringify(a));
          } else {
            out.push(String(a));
          }
        } catch (e) {
          out.push(Object.prototype.toString.call(a));
        }
      }
      var joined = out.join(' ');
      return joined.length > LIMIT ? joined.slice(0, LIMIT) + '…' : joined;
    }
    function post(level, message, source, line) {
      try {
        window.webkit.messageHandlers.__CONSOLE__.postMessage({
          level: level, message: message, source: source || '', line: line || 0
        });
      } catch (e) {}
    }
    ['debug', 'log', 'info', 'warn', 'error'].forEach(function (level) {
      var original = console[level];
      console[level] = function () {
        post(level, text(arguments));
        if (original) { try { original.apply(console, arguments); } catch (e) {} }
      };
    });
    window.addEventListener('error', function (e) {
      post('error', e.message || String(e.error || 'error'), e.filename, e.lineno);
    });
    window.addEventListener('unhandledrejection', function (e) {
      var r = e.reason;
      post('error', 'unhandledrejection: ' + ((r && r.message) ? r.message : String(r)));
    });
  })();
  """.replacingOccurrences(of: "__CONSOLE__", with: consoleHandler)

  // --------------------------------------------------------- §7.3 文件选择器

  /// §7.3 iOS 必须由壳接管 `<input type="file">`。
  ///
  /// WKWebView 自带的处理会先弹「照片图库 / 拍照或录像 / 选取文件」菜单，且没有公开接口
  /// 去掉，所以这里在 document-start 把弹出路径全拦下来（用户点击、`click()`、
  /// `showPicker()`），交给原生的 `PHPickerViewController`。只用公开 API，不 hook
  /// WebKit 私有类（§7.3 明确禁止 `WKFileUploadPanel` 之类的做法）。
  ///
  /// 文件交回页面走分块：视频可能几百 MB，整个转 base64 一次性交给页面会直接 OOM
  /// （§7.3.4）。页面按块向 `shellFileChunk` 拉，每块 base64 后不超过 2 MB。
  static let fileInputScript = """
  (function () {
    if (window.__ssgFileBridge) { return; }
    var seq = 0;
    var pending = Object.create(null);

    function post(name, payload) {
      try {
        window.webkit.messageHandlers[name].postMessage(payload);
        return true;
      } catch (e) {
        return false;
      }
    }

    function intercept(input) {
      var id = String(++seq);
      pending[id] = input;
      var ok = post('__PICK__', {
        requestId: id,
        accept: input.getAttribute('accept') || '',
        multiple: !!input.multiple
      });
      if (!ok) { delete pending[id]; }
      return ok;
    }

    // 用户直接点击。捕获阶段 preventDefault 掉，WebKit 就不会弹它自己的菜单；
    // 页面自己的 click 处理照常跑，不用 stopPropagation。
    document.addEventListener('click', function (e) {
      var node = e.target;
      if (!node || typeof node.closest !== 'function') { return; }
      var input = node.closest('input[type="file"]');
      if (!input || input.disabled) { return; }
      if (intercept(input)) { e.preventDefault(); }
    }, true);

    // 程序触发：input.click()
    var nativeClick = HTMLElement.prototype.click;
    HTMLElement.prototype.click = function () {
      if (this instanceof HTMLInputElement && this.type === 'file' && !this.disabled) {
        if (intercept(this)) { return; }
      }
      return nativeClick.apply(this, arguments);
    };

    // 程序触发：input.showPicker()
    if (HTMLInputElement.prototype.showPicker) {
      var nativeShowPicker = HTMLInputElement.prototype.showPicker;
      HTMLInputElement.prototype.showPicker = function () {
        if (this.type === 'file' && !this.disabled && intercept(this)) { return; }
        return nativeShowPicker.apply(this, arguments);
      };
    }

    function bytesOf(b64) {
      var raw = atob(b64);
      var out = new Uint8Array(raw.length);
      for (var i = 0; i < raw.length; i++) { out[i] = raw.charCodeAt(i); }
      return out;
    }

    function assemble(meta) {
      var parts = [];
      var index = 0;
      function next() {
        if (index >= meta.chunks) {
          return Promise.resolve(new File(parts, meta.name, {
            type: meta.mime, lastModified: Date.now()
          }));
        }
        return window.webkit.messageHandlers.__CHUNK__
          .postMessage({ token: meta.token, index: index })
          .then(function (b64) {
            parts.push(bytesOf(b64));
            index += 1;
            return next();
          });
      }
      return next();
    }

    window.__ssgFileBridge = {
      // 原生选完之后调这个。files 为空 = 用户取消：§7.3.5 不派发事件，
      // 下一次点附件要能再次拉起（pending 已经清掉了）。
      deliver: function (requestId, files) {
        var input = pending[requestId];
        delete pending[requestId];
        if (!input || !files || !files.length) { return; }
        var built = [];
        var i = 0;
        function step() {
          if (i >= files.length) {
            var dt = new DataTransfer();
            built.forEach(function (f) { dt.items.add(f); });
            input.files = dt.files;
            // §7.3.4 Web 以这两个事件为准取文件，不需要改动页面。
            input.dispatchEvent(new Event('input', { bubbles: true }));
            input.dispatchEvent(new Event('change', { bubbles: true }));
            return;
          }
          assemble(files[i]).then(function (file) {
            built.push(file);
            i += 1;
            step();
          }).catch(function (e) {
            if (window.console && console.error) {
              console.error('[ssg_shell] 交回文件失败', e);
            }
          });
        }
        step();
      }
    };
  })();
  """
  .replacingOccurrences(of: "__PICK__", with: filePickHandler)
  .replacingOccurrences(of: "__CHUNK__", with: fileChunkHandler)
}
