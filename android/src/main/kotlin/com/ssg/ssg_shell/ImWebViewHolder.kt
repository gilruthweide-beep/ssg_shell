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
 * §8.4 承载方式：IM 的 WebView 由 Application 级单例创建和持有，Activity 只负责挂上
 * 和取下。满足 §10.5 单实例和 §10.6 长活。
 *
 * **不能**把它换成 PlatformView（`InAppWebView` / `WebViewWidget` / 自己包的
 * `AndroidView`）。PlatformView 下 WebView 的每一帧都要和 Flutter 画面合成后才能上屏，
 * 登录页、键盘弹起收起、Tab 切换会明显掉帧。
 */
internal object ImWebViewHolder {

    private const val TAG = "SsgShell"

    private var webView: WebView? = null
    private var contextWrapper: MutableContextWrapper? = null

    /** 当前挂载的 Activity 提供的能力，没挂载时为 null。 */
    @Volatile
    var host: ShellWebViewHost? = null

    /** §1.3 自检：注入是否按 `addDocumentStartJavaScript` 真正生效。 */
    @Volatile
    var documentStartInjected: Boolean = false
        private set

    fun current(): WebView? = webView

    fun isCreated(): Boolean = webView != null

    /** 幂等。已存在就直接返回，不重建（§10.6「不要每次进入重建 WebView」）。 */
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
            // §9.6 WebView 在启动后立即开始加载入口地址，不等其他初始化做完。
            created.loadUrl(url)
        } else {
            Log.w(TAG, "entryUrl 为空，WebView 已创建但没有加载任何地址")
        }
        return created
    }

    private fun configure(web: WebView, appContext: Context, config: ShellConfig) {
        val info = ShellInjection.shellInfo(appContext, config.shellVersion)

        // §8.2 运行环境设置。
        web.settings.apply {
            javaScriptEnabled = true
            // §8.1 缺了它每次冷启动都要重新登录。
            domStorageEnabled = true
            @Suppress("DEPRECATION")
            databaseEnabled = true
            // 不设 false，否则 Web 的自动播放全部失效。
            mediaPlaybackRequiresUserGesture = false
            loadsImagesAutomatically = true
            // §8.2 省流模式会让图片不加载。
            blockNetworkImage = false
            blockNetworkLoads = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            cacheMode = WebSettings.LOAD_DEFAULT
            javaScriptCanOpenWindowsAutomatically = true
            allowFileAccess = false
            allowContentAccess = false
            // §9.3 跟随系统字体放大会让布局错位；页面已声明 user-scalable=no。
            textZoom = 100
            setSupportZoom(false)
            builtInZoomControls = false
            displayZoomControls = false
            setSupportMultipleWindows(true)
            // §2.2 必须追加，不能整段替换。
            userAgentString = userAgentString + ShellInjection.userAgentSuffix(config.shellVersion)
        }

        // §8.4 体验与性能 3：背景色与首屏一致，启动和键盘弹收时边缘不闪黑。
        web.setBackgroundColor(config.backgroundColorArgb)
        // §8.4 体验与性能 6：保持硬件加速，也不要给 WebView 套离屏绘制。
        // 默认的 LAYER_TYPE_NONE 就是随窗口硬件加速直接上屏；LAYER_TYPE_HARDWARE 反而是
        // 先画进一张离屏纹理再合成，所以这里什么都不设。
        web.isHorizontalScrollBarEnabled = false
        web.overScrollMode = WebView.OVER_SCROLL_NEVER

        // §1.2 必须在页面任何脚本执行之前完成注入。
        val fallbackScript = injectDocumentStart(web, info)

        // §3.3 对象名必须是 jsBridge。
        web.addJavascriptInterface(JsBridge(ShellCore::onWebEvent), JsBridge.NAME)

        web.webViewClient = ShellWebViewClient(config, fallbackScript)
        web.webChromeClient = ShellWebChromeClient()

        // §8.4 体验与性能 5：前台降低渲染进程被回收的概率；
        // 第二个参数 true = 不可见时自动降级，不影响后台省电。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            runCatching {
                web.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, true)
            }
        }

        // §1.4 交付标准是 shellSrc:inject。注入失败时 Web 会退到 bridge 兜底识别，
        // 那种状态拿不到 bundleId 和版本号，收不到推送，必须在日志里喊出来。
        if (!documentStartInjected) {
            Log.e(
                TAG,
                "addDocumentStartJavaScript 不可用（WebView 内核过低），容器注入会退化为 " +
                    "shellSrc:bridge，拿不到 bundleId，该设备收不到推送。见 §1.4 / §8.1。",
            )
        }
    }

    /**
     * @return 极老内核上 `addDocumentStartJavaScript` 不可用时的兜底脚本，否则 null。
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
        // 兜底而不是替代：§1.2 明确说 onPageStarted 里的 evaluateJavascript 与首个
        // bundle 存在竞态、不接受。这里只是让极老内核上不至于完全没有容器标记。
        return if (documentStartInjected) null else script
    }

    /** §4 Native → Web。`window.__ssgShell` 页面加载早期不存在，调用前必须判空。 */
    fun callWeb(method: String, arg: String? = null) {
        val web = webView ?: return
        val call = if (arg == null) "$method()" else "$method($arg)"
        val js = "window.__ssgShell && window.__ssgShell.$call"
        runCatching { web.evaluateJavascript(js, null) }
            .onFailure { Log.w(TAG, "callWeb($method) 失败", it) }
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

    /** §10.2 实现 onPause/onResume，让 `visibilitychange` 成为第二条独立通道。 */
    fun onResumeWeb() {
        webView?.let {
            it.onResume()
            // §10.3 绝不调 pauseTimers()：它冻结整个 WebView 的 JS 定时器，
            // 包括 Worker 里的心跳和探测，而主线程没有定时器兜底。
            // resumeTimers 单独调是安全的（没有配对的 pause 时是空操作）。
            runCatching { it.resumeTimers() }
        }
    }

    fun onPauseWeb() {
        // 只调 onPause（暂停渲染和可见性），不调 pauseTimers（§10.3）。
        webView?.onPause()
    }

    fun reload() {
        webView?.reload()
    }

    fun currentUrl(): String = webView?.url.orEmpty()

    fun userAgent(): String = webView?.settings?.userAgentString.orEmpty()

    /**
     * §11.2.3 销毁并重建。
     *
     * **必须先结束渲染进程。** 同一个 App 的所有 WebView 共用一个渲染进程，死循环卡住
     * 的是这个进程；只换 WebView 实例的话新实例同样卡住，永远加载不出来。
     *
     * `terminate()` 成功时不在这里重建 —— 终止会触发 §7.1 的 `onRenderProcessGone`，
     * 由那条路径统一重建，避免建两个实例（§10.5）。
     *
     * @return true 表示已经发起终止、重建会在 onRenderProcessGone 里完成。
     */
    fun terminateRenderProcess(): Boolean {
        val web = webView ?: return false
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_VIEW_RENDERER_TERMINATE)) {
            Log.w(TAG, "内核不支持 WEB_VIEW_RENDERER_TERMINATE，只能直接换实例（§11.2.3）")
            return false
        }
        return runCatching {
            WebViewCompat.getWebViewRenderProcess(web)?.terminate() ?: false
        }.getOrDefault(false)
    }

    /** 直接换实例。渲染进程已经没了（onRenderProcessGone）或内核不支持 terminate 时走这里。 */
    fun recreate(context: Context, config: ShellConfig): WebView {
        destroy()
        val fresh = get(context, config)
        host?.onWebViewReplaced(fresh)
        return fresh
    }

    /**
     * 只在重建路径上调。
     *
     * §8.3：这里刻意**不**调 `clearCache()` / `clearWebStorage()` /
     * `WebStorage.deleteAllData()` / `CookieManager.removeAllCookies()`。清存储会让用户
     * 被登出、本地消息缓存全失、`eventRegister` 的「每设备一次」标记被抹掉导致渠道注册
     * 数虚高。「启动时清一次缓存保证干净」是禁止的做法。
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
        }.onFailure { Log.w(TAG, "destroy WebView 失败", it) }
        contextWrapper = null
    }

    /**
     * Activity 挂上 / 取下时切换 base context。
     *
     * WebView 的 IME、下拉选择、全屏等行为需要一个 Activity context；预加载阶段只有
     * applicationContext，所以用 [MutableContextWrapper] 在挂载时换过去，取下时换回来，
     * 避免 Activity 泄漏。
     */
    fun attachContext(context: Context) {
        contextWrapper?.baseContext = context
    }

    fun detachContext(appContext: Context) {
        contextWrapper?.baseContext = appContext.applicationContext
    }
}
