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
 * §7.1 WebChromeClient callbacks.
 *
 * File selection, microphone permission, fullscreen video, window.open, and console forwarding are handled here.
 * Missing any callback leaves a feature unresponsive without exposing an error to the Web application.
 */
internal class ShellWebChromeClient : WebChromeClient() {

    /**
     * §7.1 / §7.3 Photo/video attachments and avatar selection; missing handling leaves the attachment button unresponsive.
     *
     * Delegate to [ShellWebViewHost], opening the system photo picker directly without intermediate menus,
     * and avoid fileChooserParams.createIntent(), which opens a document picker.
     */
    override fun onShowFileChooser(
        webView: WebView,
        filePathCallback: ValueCallback<Array<Uri>?>,
        fileChooserParams: FileChooserParams,
    ): Boolean {
        val host = ImWebViewHolder.host
        if (host == null) {
            // Without an attached Activity the picker cannot open. §7.3.3 requires returning null;
            // an unresolved callback would permanently disable subsequent attachment selection.
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

    /** §7.1 Grant RESOURCE_AUDIO_CAPTURE to enable voice recording. */
    override fun onPermissionRequest(request: PermissionRequest) {
        val host = ImWebViewHolder.host
        if (host == null) {
            request.deny()
            return
        }
        host.requestAudioPermission(request)
    }

    /** §7.1 Remove permission UI to avoid leaving a dialog open. */
    override fun onPermissionRequestCanceled(request: PermissionRequest) {
        ImWebViewHolder.host?.cancelPermissionRequest(request)
    }

    /** §7.1 Fullscreen video. */
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
     * §7.1 target="_blank" / window.open handling; missing it makes links unresponsive.
     *
     * Match iOS createWebViewWith behavior (§7.2: return nil and load in the existing WebView):
     * open external links in the system browser and same-origin links in the current instance.
     *
     * A temporary WebView is needed to capture the target URL: Chromium routes the new window's first navigation
     * to the transport instance. It never loads a document because shouldOverrideUrlLoading returns true,
     * so it does not participate in the §10.5 BroadcastChannel primary-instance election.
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
            // Do not destroy synchronously inside the callback while WebView is still on its own call stack.
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

            // Every WebView in the app shares one render process. When the watchdog terminates it (§11.2.3) while
            // this probe is alive, the default `false` would take the whole app down with it.
            override fun onRenderProcessGone(
                probeView: WebView,
                detail: android.webkit.RenderProcessGoneDetail,
            ): Boolean {
                dispose()
                return true
            }
        }
        transport.webView = probe
        resultMsg.sendToTarget()
        // Some calls, such as window.open(''), never navigate; clean up the empty temporary view to avoid leaks.
        handler.postDelayed({ dispose() }, PROBE_TTL_MS)
        return true
    }

    /** §7.1 / §11.6 Forward console output to native logs for production diagnostics. */
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
