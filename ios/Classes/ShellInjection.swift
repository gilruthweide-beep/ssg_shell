import Foundation
import UIKit
import WebKit

/// §1.1 / §1.2 / §2.2 / §7.3 / §11.6: all scripts and fields injected into the page.
enum ShellInjection {

  // ------------------------------------------------------- Message handler names

  /// §3.2 Register all ten handlers; missing handlers throw errors caught by Web code, but lose events.
  static let eventHandlers = [
    "eventWebReady", "eventRegister", "eventLogin", "eventLogout",
    "eventMessageSent", "eventWebAlive",
    "eventChatOpen", "eventChatClose", "eventChatRead", "eventUnreadCount",
  ]

  /// §11.6 Console forwarding. WKWebView has no onConsoleMessage callback, so inject a hook.
  static let consoleHandler = "shellConsole"
  /// §7.3.1 Notify native code after intercepting a file input.
  static let filePickHandler = "shellFilePick"
  /// §7.3.4 The page fetches file chunks through WKScriptMessageHandlerWithReply.
  static let fileChunkHandler = "shellFileChunk"

  // -------------------------------------------------------------- §1.1 Fields

  /// §1.1 Six required fields. Missing platform invalidates injection; missing bundleId prevents push routing.
  static func shellInfo(shellVersion: String) -> ShellInfo {
    ShellInfo(
      platform: .ios,
      bundleId: Bundle.main.bundleIdentifier ?? "",
      shellVersion: shellVersion,
      webviewVersion: webKitVersion(),
      // §11.5 Use the original model identifier (such as iPhone15,2) to diagnose device-specific connection freezes;
      // marketing names are less precise for this purpose.
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

  /// WebKit updates with iOS and cannot be updated independently; this value is diagnostic only (§1.1 / §11.5).
  static func webKitVersion() -> String {
    let bundle = Bundle(identifier: "com.apple.WebKit")
      ?? Bundle(path: "/System/Library/Frameworks/WebKit.framework")
    let info = bundle?.infoDictionary
    if let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty { return short }
    if let build = info?["CFBundleVersion"] as? String, !build.isEmpty { return build }
    return ""
  }

  /// §2.2 config.applicationNameForUserAgent is appended by WebKit to the default user agent.
  ///
  /// Do not replace customUserAgent; both the Web application and server use it to identify the platform.
  /// from tokens such as `Android`, `iPhone`, and `iPad`, which a replacement agent could remove.
  static func applicationNameForUserAgent(shellVersion: String) -> String {
    "SSGShell/\(shellVersion) iOS"
  }

  // -------------------------------------------------------------- §1.2 Injection

  /// §1.2 Inject before any page script executes. The Web application evaluates constants at module load
  /// for container detection, reconnection settings, and install-card visibility; injection after the first bundle is too late.
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

  // ------------------------------------------------------- §11.6 Console forwarding

  /// Wrap console methods while continuing to call their original implementations.
  ///
  /// §9.6 Debug injection must preserve existing window fields. Add only
  /// the __ssgConsoleHooked marker, leaving __ssgShell and business fields untouched.
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

  // --------------------------------------------------------- §7.3 File selection

  /// §7.3 The iOS shell must handle <input type="file"> itself.
  ///
  /// WKWebView normally shows an intermediate photo library / camera / file menu with no public API to remove it.
  /// At document start, intercept every path that opens the picker: user clicks, click(),
  /// and showPicker(). Delegate them to PHPickerViewController using public APIs only;
  /// private WebKit hooks such as WKFileUploadPanel are prohibited by §7.3.
  ///
  /// Deliver files in chunks: converting hundreds of MB of video to base64 at once could exhaust memory
  /// (§7.3.4). The page requests shellFileChunk chunks, each below 2 MB after encoding.
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

    // For user clicks, preventDefault during capture to suppress WebKit's menu;
    // allow the page's click handlers to run normally without stopPropagation.
    document.addEventListener('click', function (e) {
      var node = e.target;
      if (!node || typeof node.closest !== 'function') { return; }
      var input = node.closest('input[type="file"]');
      if (!input || input.disabled) { return; }
      if (intercept(input)) { e.preventDefault(); }
    }, true);

    // Programmatic input.click() calls.
    var nativeClick = HTMLElement.prototype.click;
    HTMLElement.prototype.click = function () {
      if (this instanceof HTMLInputElement && this.type === 'file' && !this.disabled) {
        if (intercept(this)) { return; }
      }
      return nativeClick.apply(this, arguments);
    };

    // Programmatic input.showPicker() calls.
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
      // Called after native selection. An empty files array means cancellation: do not dispatch events (§7.3.5),
      // and clear pending state so the next attachment tap can work again.
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
            // §7.3.4 The Web application uses these two events to read files; no page changes are required.
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
              console.error('[ssg_shell] Unable to deliver selected files', e);
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
