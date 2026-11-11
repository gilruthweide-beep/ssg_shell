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
 * §7.1 `WebViewClient` callbacks.
 *
 * Missing callbacks leave features unresponsive without exposing errors to the Web application.
 */
internal class ShellWebViewClient(
    private val config: ShellConfig,
    /** §1.2 Fallback script for old engines without addDocumentStartJavaScript. */
    private val fallbackInjection: String?,
) : WebViewClient() {

    private val entryHost: String? = config.entryHost()

    override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
        super.onPageStarted(view, url, favicon)
        // §11.2.3 Reaching this callback confirms that reload actually started loading.
        ShellCore.onPageStarted(url)
        val script = fallbackInjection
        if (script != null) {
            // This fallback still races the first bundle and is only better than no injection; see §1.2 / §1.4.
            runCatching { view.evaluateJavascript(script, null) }
        }
    }

    override fun onPageFinished(view: WebView, url: String?) {
        super.onPageFinished(view, url)
        ShellCore.onPageFinished(url)
    }

    /**
     * §7.1 Delegate external links, `tel:`, and `mailto:` to the system instead of trapping navigation inside the WebView.
     *
     * Allow same-origin HTTPS URLs unchanged, without rewriting, redirecting, or intercepting them.
     * `blob:` / `data:` navigations support Web media previews and must not be treated as external links.
     */
    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
        handleNavigation(request.url)

    @Deprecated("Legacy pre-API-23 signature retained for older-device compatibility")
    @Suppress("DEPRECATION")
    override fun shouldOverrideUrlLoading(view: WebView, url: String?): Boolean =
        handleNavigation(url?.let { runCatching { Uri.parse(it) }.getOrNull() })

    private fun handleNavigation(uri: Uri?): Boolean {
        if (uri == null) return false
        val scheme = uri.scheme?.lowercase().orEmpty()
        return when {
            // Allow the Web media-preview channel so photos and videos can open.
            scheme in PASS_THROUGH_SCHEMES -> false
            scheme == "http" || scheme == "https" -> {
                if (isInternal(uri)) {
                    false // Same origin; allow unchanged.
                } else {
                    ImWebViewHolder.host?.openExternal(uri.toString()) ?: false
                }
            }
            // tel:, mailto:, intent:, app store links, etc. all go to the system.
            // Even when no app can handle them, do not pass them to the WebView: it cannot load these schemes, the main frame would report
            // ERR_UNKNOWN_URL_SCHEME, and the native retry page would cover the entire IM.
            else -> {
                ImWebViewHolder.host?.openExternal(uri.toString())
                true
            }
        }
    }

    private fun isInternal(uri: Uri): Boolean {
        val host = uri.host?.lowercase() ?: return false
        val entry = entryHost?.lowercase() ?: return true // Allow navigation when configuration is unavailable to avoid blocking the application.
        return host == entry || host.endsWith(".$entry")
    }

    /** §7.1 Replace initial-load failures with a native retry screen instead of default WebView error UI. */
    override fun onReceivedError(
        view: WebView,
        request: WebResourceRequest,
        error: WebResourceError,
    ) {
        super.onReceivedError(view, request, error)
        if (!request.isForMainFrame) return // Let the Web application handle subresource failures without covering the page.
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
     * §9.6 Do not blindly `proceed()` on SSL errors or silently `cancel()` into a blank page;
     * show an error the user can act on.
     */
    override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
        handler.cancel()
        ShellCore.onSslError(error.primaryError)
    }

    /**
     * §7.1 The renderer was reclaimed or explicitly terminated under §11.2.3.
     *
     * The old WebView is unusable: destroy it and create a new one loading the landing URL instead of calling `reload()`.
     * Return `true` in all cases; returning `false` would also terminate the application.
     */
    override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail?): Boolean {
        val crashed = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            detail?.didCrash() == true
        Log.w(TAG, "onRenderProcessGone(didCrash=$crashed); destroy the old instance and recreate it (§7.1)")
        ShellCore.onRenderProcessGone(crashed)
        return true
    }

    private companion object {
        const val TAG = "SsgShell"
        val PASS_THROUGH_SCHEMES = setOf("blob", "data", "about", "javascript", "file")
    }
}
