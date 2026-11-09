package com.ssg.ssg_shell

import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.view.View
import android.webkit.ConsoleMessage
import android.webkit.PermissionRequest
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebView
import java.util.concurrent.atomic.AtomicBoolean

/**
 * §7.1 `WebChromeClient` 回调。
 *
 * 文件选择、麦克风授权、全屏视频、`window.open`、console 转发都在这里。
 * 任何一项缺失都是「点了没反应」，Web 侧看不到错误。
 */
internal class ShellWebChromeClient : WebChromeClient() {

    /**
     * §7.1 / §7.3 发图片和视频 / 改头像。不实现附件按钮完全没反应。
     *
     * 实现交给 [ShellWebViewHost]：必须直接进系统相册，中间不出现任何选择菜单，
     * 也不能用 `fileChooserParams.createIntent()`（它打开的是文档选择器）。
     */
    override fun onShowFileChooser(
        webView: WebView,
        filePathCallback: ValueCallback<Array<Uri>?>,
        fileChooserParams: FileChooserParams,
    ): Boolean {
        val host = ImWebViewHolder.host
        if (host == null) {
            // 没有 Activity 挂载时拉不起选择器。§7.3.3：必须回调 null，
            // 漏了这一步此后点附件按钮永久无反应。
            filePathCallback.onReceiveValue(null)
            return true
        }
        return if (host.openPhotoPicker(fileChooserParams, filePathCallback)) {
            true
        } else {
            filePathCallback.onReceiveValue(null)
            true
        }
    }

    /** §7.1 授予 `RESOURCE_AUDIO_CAPTURE`，不实现语音录不了。 */
    override fun onPermissionRequest(request: PermissionRequest) {
        val host = ImWebViewHolder.host
        if (host == null) {
            request.deny()
            return
        }
        host.requestAudioPermission(request)
    }

    /** §7.1 清理授权 UI，不实现会残留弹窗。 */
    override fun onPermissionRequestCanceled(request: PermissionRequest) {
        ImWebViewHolder.host?.cancelPermissionRequest(request)
    }

    /** §7.1 视频全屏。 */
    override fun onShowCustomView(view: View, callback: CustomViewCallback) {
        val host = ImWebViewHolder.host
        if (host == null) {
            callback.onCustomViewHidden()
            return
        }
        host.showCustomView(view, callback)
    }

    override fun onHideCustomView() {
        ImWebViewHolder.host?.hideCustomView()
    }

    /**
     * §7.1 `target="_blank"` / `window.open`。不实现点链接没反应。
     *
     * 行为对齐 iOS 的 `createWebViewWith`（§7.2「返回 nil 并在当前 WebView 加载」）：
     * 外链交给系统浏览器，同源地址在当前实例里加载。
     *
     * 拿目标 URL 只能靠一个临时 WebView —— Chromium 只把新窗口的首次导航派给
     * transport 里的那个实例。它不会加载任何文档（`shouldOverrideUrlLoading` 直接
     * 返回 true），所以不参与 §10.5 的 BroadcastChannel 主实例选举。
     */
    override fun onCreateWindow(
        view: WebView,
        isDialog: Boolean,
        isUserGesture: Boolean,
        resultMsg: Message?,
    ): Boolean {
        val transport = resultMsg?.obj as? WebView.WebViewTransport ?: return false
        val probe = WebView(view.context)
        val handler = Handler(Looper.getMainLooper())
        val disposed = AtomicBoolean(false)
        fun dispose() {
            if (!disposed.compareAndSet(false, true)) return
            // 不在回调里同步 destroy：那是在 WebView 自己的调用栈上拆自己。
            handler.post { runCatching { probe.destroy() } }
        }

        probe.webViewClient = object : android.webkit.WebViewClient() {
            override fun shouldOverrideUrlLoading(
                probeView: WebView,
                request: android.webkit.WebResourceRequest,
            ): Boolean {
                ImWebViewHolder.host?.openNewWindow(request.url?.toString())
                dispose()
                return true
            }
        }
        transport.webView = probe
        resultMsg.sendToTarget()
        // window.open('') 之类不会产生导航，兜底回收，避免泄漏一个空实例。
        handler.postDelayed({ dispose() }, PROBE_TTL_MS)
        return true
    }

    /** §7.1 / §11.6 转发到原生日志，不实现线上问题无法定位。 */
    override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean {
        ShellCore.onConsoleMessage(
            level = when (consoleMessage.messageLevel()) {
                ConsoleMessage.MessageLevel.DEBUG -> ConsoleLevel.DEBUG
                ConsoleMessage.MessageLevel.LOG -> ConsoleLevel.LOG
                ConsoleMessage.MessageLevel.TIP -> ConsoleLevel.INFO
                ConsoleMessage.MessageLevel.WARNING -> ConsoleLevel.WARNING
                ConsoleMessage.MessageLevel.ERROR -> ConsoleLevel.ERROR
                else -> ConsoleLevel.LOG
            },
            message = consoleMessage.message().orEmpty(),
            source = consoleMessage.sourceId(),
            line = consoleMessage.lineNumber().toLong(),
        )
        return true
    }

    private companion object {
        const val PROBE_TTL_MS = 5_000L
    }
}
