package com.ssg.ssg_shell

import android.graphics.Bitmap
import android.net.Uri
import android.net.http.SslError
import android.os.Build
import android.util.Log
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient

/**
 * §7.1 `WebViewClient` 回调。
 *
 * 这里每一项不实现都表现为某个功能「点了没反应」，而 Web 侧看不到任何错误。
 */
internal class ShellWebViewClient(
    private val config: ShellConfig,
    /** §1.2 极老内核上 `addDocumentStartJavaScript` 不可用时的兜底脚本。 */
    private val fallbackInjection: String?,
) : WebViewClient() {

    private val entryHost: String? = config.entryHost()

    override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
        super.onPageStarted(view, url, favicon)
        // §11.2.3 reload 是否真的生效，就看有没有走到这里。
        ShellCore.onPageStarted(url)
        val script = fallbackInjection
        if (script != null) {
            // 与首个 bundle 有竞态，只是比什么都没有好，见 §1.2 / §1.4。
            runCatching { view.evaluateJavascript(script, null) }
        }
    }

    override fun onPageFinished(view: WebView, url: String?) {
        super.onPageFinished(view, url)
        ShellCore.onPageFinished(url)
    }

    /**
     * §7.1 外链、`tel:`、`mailto:` 交给系统；不实现的话外链在 WebView 里打开，用户出不来。
     *
     * 同源 HTTPS 必须**原样放行**，不做改写、重定向或拦截。
     * `blob:` / `data:` 的导航不是外链，不要拦 —— 那是 Web 预览媒体的通道。
     */
    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
        handleNavigation(request.url)

    @Deprecated("API 23 以下的旧签名，保留以兼容老设备")
    @Suppress("DEPRECATION")
    override fun shouldOverrideUrlLoading(view: WebView, url: String?): Boolean =
        handleNavigation(url?.let { runCatching { Uri.parse(it) }.getOrNull() })

    private fun handleNavigation(uri: Uri?): Boolean {
        if (uri == null) return false
        val scheme = uri.scheme?.lowercase().orEmpty()
        return when {
            // Web 预览媒体的通道，拦了图片视频就打不开。
            scheme in PASS_THROUGH_SCHEMES -> false
            scheme == "http" || scheme == "https" -> {
                if (isInternal(uri)) {
                    false // 同源，原样放行。
                } else {
                    ImWebViewHolder.host?.openExternal(uri.toString()) ?: false
                }
            }
            // tel:、mailto:、intent:、市场链接等，一律交给系统。
            else -> ImWebViewHolder.host?.openExternal(uri.toString()) ?: false
        }
    }

    private fun isInternal(uri: Uri): Boolean {
        val host = uri.host?.lowercase() ?: return false
        val entry = entryHost?.lowercase() ?: return true // 配置缺失时一律放行，别把自己挡在外面
        return host == entry || host.endsWith(".$entry")
    }

    /** §7.1 首屏加载失败 → 原生重试页，不要停在 WebView 默认错误页。 */
    override fun onReceivedError(
        view: WebView,
        request: WebResourceRequest,
        error: WebResourceError,
    ) {
        super.onReceivedError(view, request, error)
        if (!request.isForMainFrame) return // 子资源失败由 Web 自己兜，不要弹错误页
        val description = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            "${error.errorCode} ${error.description}"
        } else {
            "load failed"
        }
        ShellCore.onMainFrameLoadFailed(request.url.toString(), description)
    }

    override fun onReceivedHttpError(
        view: WebView,
        request: WebResourceRequest,
        errorResponse: WebResourceResponse,
    ) {
        super.onReceivedHttpError(view, request, errorResponse)
        if (!request.isForMainFrame) return
        ShellCore.onMainFrameLoadFailed(
            request.url.toString(),
            "HTTP ${errorResponse.statusCode}",
        )
    }

    /**
     * §9.6 SSL 错误不要无脑 `proceed()`，也不要静默 `cancel()` 停在白屏，
     * 要给用户可见提示。
     */
    override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
        handler.cancel()
        ShellCore.onSslError(error.primaryError)
    }

    /**
     * §7.1 渲染进程被回收或被主动结束（§11.2.3 的 `terminate()`）。
     *
     * 旧实例已不可用，不能对它 `reload()`：必须销毁旧 WebView、新建一个加载入口地址。
     * 返回 `false` 会连带杀掉 App，所以无论如何都返回 `true`。
     */
    override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail?): Boolean {
        val crashed = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            detail?.didCrash() == true
        Log.w(TAG, "onRenderProcessGone(didCrash=$crashed)，销毁旧实例并重建（§7.1）")
        ShellCore.onRenderProcessGone(crashed)
        return true
    }

    private companion object {
        const val TAG = "SsgShell"
        val PASS_THROUGH_SCHEMES = setOf("blob", "data", "about", "javascript", "file")
    }
}
