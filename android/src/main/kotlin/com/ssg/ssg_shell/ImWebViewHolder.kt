package com.ssg.ssg_shell

import android.annotation.SuppressLint
import android.content.Context
import android.content.MutableContextWrapper
import android.os.Build
import android.util.Log
import android.view.ViewGroup
import android.webkit.WebSettings
import android.webkit.WebView
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature

/**
 * §8.4 An application-level singleton creates and owns the IM WebView; Activities only attach
 * and detach it, meeting §10.5 single-instance and §10.6 lifetime requirements.
 *
 * **Do not replace it with a PlatformView** (`InAppWebView`, `WebViewWidget`, or a custom
 * `AndroidView`). PlatformViews composite every WebView frame with Flutter before presentation,
 * causing visible frame drops on login, keyboard animations, and tab changes.
 */
internal object ImWebViewHolder {

    private const val TAG = "SsgShell"

    private var webView: WebView? = null
    private var contextWrapper: MutableContextWrapper? = null

    /** Capabilities supplied by the attached Activity, or null while detached. */
    @Volatile
    var host: ShellWebViewHost? = null

    /** §1.3 Check that addDocumentStartJavaScript injection is actually active. */
    @Volatile
    var documentStartInjected: Boolean = false
        private set

    fun current(): WebView? = webView

    fun isCreated(): Boolean = webView != null

    /** Idempotent: return the existing instance instead of recreating it on each entry (§10.6). */
    @SuppressLint("SetJavaScriptEnabled")
    fun get(context: Context, config: ShellConfig): WebView {
        webView?.let { return it }
        val wrapper = MutableContextWrapper(context.applicationContext)
        val created = WebView(wrapper)
        contextWrapper = wrapper
        webView = created
        configure(created, context.applicationContext, config)
        val url = config.resolvedUrl()
        if (url.isNotBlank()) {
            // §9.6 Load the landing URL immediately after startup without waiting for other initialization.
            created.loadUrl(url)
        } else {
            Log.w(TAG, "entryUrl is empty; WebView was created without loading a URL")
        }
        return created
    }

    private fun configure(web: WebView, appContext: Context, config: ShellConfig) {
        val info = ShellInjection.shellInfo(appContext, config.shellVersion)

        // §8.2 Runtime environment settings.
        web.settings.apply {
            javaScriptEnabled = true
            // §8.1 Without persistent storage, every cold start would require login again.
            domStorageEnabled = true
            @Suppress("DEPRECATION")
            databaseEnabled = true
            // Keep autoplay enabled so Web media playback continues to work.
            mediaPlaybackRequiresUserGesture = false
            loadsImagesAutomatically = true
            // §8.2 Data-saving settings can prevent images from loading.
            blockNetworkImage = false
            blockNetworkLoads = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            cacheMode = WebSettings.LOAD_DEFAULT
            javaScriptCanOpenWindowsAutomatically = true
            allowFileAccess = false
            allowContentAccess = false
            // §9.3 System font scaling can break page layout; the page already declares user-scalable=no.
            textZoom = 100
            setSupportZoom(false)
            builtInZoomControls = false
            displayZoomControls = false
            setSupportMultipleWindows(true)
            // §2.2 Append to the original user agent instead of replacing it.
            userAgentString = userAgentString + ShellInjection.userAgentSuffix(config.shellVersion)
        }

        // §8.4 Performance 3: match the first-screen background to avoid edge flashes during startup and keyboard transitions.
        web.setBackgroundColor(config.backgroundColorArgb)
        // §8.4 Performance 6: keep hardware acceleration and do not wrap the WebView in offscreen rendering.
        // The default LAYER_TYPE_NONE goes straight to screen with the window's hardware acceleration; LAYER_TYPE_HARDWARE instead
        // draws into an offscreen texture first and then composites it, so nothing is set here.
        web.isHorizontalScrollBarEnabled = false
        web.overScrollMode = WebView.OVER_SCROLL_NEVER

        // §1.2 Inject before any page script executes.
        val fallbackScript = injectDocumentStart(web, info)

        // §3.3 The bridge object must be named jsBridge.
        web.addJavascriptInterface(JsBridge(ShellCore::onWebEvent), JsBridge.NAME)

        web.webViewClient = ShellWebViewClient(config, fallbackScript)
        web.webChromeClient = ShellWebChromeClient()

        // §8.4 Performance 5: reduce the chance of foreground renderer reclamation;
        // the second argument, true, lowers priority when hidden to preserve background power savings.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            runCatching {
                web.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, true)
            }
        }

        // §1.4 The required injection status is shellSrc:inject. Bridge fallback detection cannot supply
        // bundleId or version fields, preventing push routing; log injection failures explicitly.
        if (!documentStartInjected) {
            Log.e(
                TAG,
                "addDocumentStartJavaScript is unavailable on this outdated engine; container detection falls back to" +
                    " shellSrc:bridge without bundleId, preventing push routing. See §1.4 / §8.1.",
            )
        }
    }

    /**
     * @return A fallback script only when `addDocumentStartJavaScript` is unavailable on an old engine, otherwise null.
     */
    private fun injectDocumentStart(web: WebView, info: ShellInfo): String? {
        val script = ShellInjection.buildScript(info)
        documentStartInjected = if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            runCatching {
                WebViewCompat.addDocumentStartJavaScript(web, script, setOf("*"))
            }.isSuccess
        } else {
            false
        }
        // This is a fallback, not a replacement: §1.2 rejects evaluateJavascript from onPageStarted because it races
        // the first bundle. The fallback only ensures very old engines retain some container detection.
        return if (documentStartInjected) null else script
    }

    /** §4 Native → Web. Check window.__ssgShell before calls because it is absent during early page loading. */
    fun callWeb(method: String, arg: String? = null) {
        val web = webView ?: return
        val call = if (arg == null) "$method()" else "$method($arg)"
        val js = "window.__ssgShell && window.__ssgShell.$call"
        runCatching { web.evaluateJavascript(js, null) }
            .onFailure { Log.w(TAG, "callWeb($method) failed", it) }
    }

    fun evaluate(js: String, onResult: ((String?) -> Unit)? = null) {
        val web = webView
        if (web == null) {
            onResult?.invoke(null)
            return
        }
        runCatching { web.evaluateJavascript(js) { onResult?.invoke(it) } }
            .onFailure { onResult?.invoke(null) }
    }

    /** §10.2 Use onPause/onResume so visibilitychange provides a second independent foreground signal. */
    fun onResumeWeb() {
        webView?.let {
            it.onResume()
            // §10.3 Never call pauseTimers(): it freezes JavaScript timers throughout the WebView,
            // including Worker heartbeat and liveness checks, leaving the main thread without a timer fallback.
            // Calling resumeTimers alone is safe; it is a no-op without a matching pause.
            runCatching { it.resumeTimers() }
        }
    }

    fun onPauseWeb() {
        // Call onPause to pause rendering and visibility, without pauseTimers (§10.3).
        webView?.onPause()
    }

    fun reload() {
        webView?.reload()
    }

    fun currentUrl(): String = webView?.url.orEmpty()

    fun userAgent(): String = webView?.settings?.userAgentString.orEmpty()

    /**
     * §11.2.3 Destroy and recreate.
     *
     * **Terminate the renderer first.** All WebViews in the application share one renderer process;
     * replacing only the WebView would leave the new instance blocked in the same process.
     *
     * When `terminate()` succeeds, let the resulting §7.1 `onRenderProcessGone` callback
     * own recreation to avoid creating two instances (§10.5).
     *
     * @return True when termination was requested and onRenderProcessGone will complete recreation.
     */
    fun terminateRenderProcess(): Boolean {
        val web = webView ?: return false
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_VIEW_RENDERER_TERMINATE)) {
            Log.w(TAG, "Engine lacks WEB_VIEW_RENDERER_TERMINATE; replacing the instance directly (§11.2.3)")
            return false
        }
        return runCatching {
            WebViewCompat.getWebViewRenderProcess(web)?.terminate() ?: false
        }.getOrDefault(false)
    }

    /** Replace the instance after renderer termination (onRenderProcessGone), or when terminate is unsupported. */
    fun recreate(context: Context, config: ShellConfig): WebView {
        destroy()
        val fresh = get(context, config)
        host?.onWebViewReplaced(fresh)
        return fresh
    }

    /**
     * Call only during recreation.
     *
     * §8.3 Intentionally avoid `clearCache()`, `clearWebStorage()`,
     * `WebStorage.deleteAllData()`, and `CookieManager.removeAllCookies()`. Clearing storage logs users out,
     * removes cached messages, and resets the once-per-device eventRegister marker, inflating attribution counts.
     * Clearing caches at startup to obtain a clean state is prohibited.
     */
    private fun destroy() {
        val web = webView ?: return
        webView = null
        documentStartInjected = false
        runCatching {
            web.stopLoading()
            web.webChromeClient = null
            web.removeJavascriptInterface(JsBridge.NAME)
            (web.parent as? ViewGroup)?.removeView(web)
            web.destroy()
        }.onFailure { Log.w(TAG, "Unable to destroy WebView", it) }
        contextWrapper = null
    }

    /**
     * Switch the base context when an Activity attaches or detaches.
     *
     * IME, selection popups, and fullscreen behavior need an Activity context. Preloading only has
     * applicationContext, so [MutableContextWrapper] switches contexts on attachment and detachment
     * to avoid retaining a destroyed Activity.
     */
    fun attachContext(context: Context) {
        contextWrapper?.baseContext = context
    }

    /**
     * Restore the application context, but only while [activity] is still the attached one. A container that
     * finished early can be destroyed after a newer one attached; it must not take the context away from it.
     */
    fun detachContext(activity: Context) {
        val wrapper = contextWrapper ?: return
        if (wrapper.baseContext === activity) wrapper.baseContext = activity.applicationContext
    }
}
