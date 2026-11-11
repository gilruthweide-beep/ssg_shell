package com.ssg.ssg_shell

import android.Manifest
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.PermissionRequest
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.addCallback
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

/**
 * §8.4 承载 IM WebView 的原生 Activity。
 *
 * WebView 不属于这个 Activity —— 它由 [ImWebViewHolder] 在 Application 级持有，
 * 这里只负责挂上、取下，以及提供那些非得有 Activity 才能做的事（[ShellWebViewHost]）：
 * 拉相册、申请麦克风、全屏视频、开外链、错误页。
 *
 * 规范要求它可以直接当冷启动的第一个 Activity（§8.4 体验与性能 2）：
 * `installSplashScreen()` + `setKeepOnScreenCondition` 把系统启动图一直撑到
 * `eventWebReady`，中间不出现任何别的加载界面（§9.6）。
 */
internal class ImActivity : ComponentActivity(), ShellWebViewHost {

    private lateinit var container: FrameLayout

    private val main = Handler(Looper.getMainLooper())

    /** §9.6 splash 还没撤。撤除条件：收到 `eventWebReady`，或到达上限。 */
    private var splashUp = true

    /** `setKeepOnScreenCondition` 每帧回调一次，用时间戳判断比用标志位省事。 */
    private var splashDeadlineAtMs = 0L
    private var splashTimeoutTask: Runnable? = null

    private var picker: PhotoPickerDelegate? = null

    private var errorView: View? = null

    /** §7.1 全屏视频。 */
    private var fullscreenView: View? = null
    private var fullscreenCallback: WebChromeClient.CustomViewCallback? = null

    /** §7.1 `onPermissionRequest` 里挂起的那次麦克风请求。 */
    private var pendingAudio: PermissionRequest? = null

    /** 向系统发起麦克风申请的时刻，用来分辨「系统没弹框就直接拒了」。 */
    private var audioRequestedAtMs = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        // §9.6 必须在 super.onCreate 之前装上，否则这一帧已经用 postSplashScreenTheme 画了。
        val splash = installSplashScreen()
        super.onCreate(savedInstanceState)

        // 正常情况下 androidx.startup 早在 Application 之前就装配好了（见
        // ShellStartupInitializer）。这一句只兜一种情况：宿主把那个 provider
        // 用 tools:node="remove" 去掉了，而这个 Activity 又是冷启动的第一个。
        ShellStartupInitializer.ensure(this)

        // §8.4 体验与性能 2：B 面未开启时转去 A 面并结束自己。
        // 判断只读本地缓存（§9.6「把上次的结果缓存在本地，冷启动直接按缓存走」），
        // 不等 Dart，也就不会以等待界面的形式出现在用户面前。
        if (!ShellCore.isBSideEnabled()) {
            val aSide = ShellCore.aSideIntent()
            if (aSide == null) {
                Log.e(
                    TAG,
                    "B 面未开启，且没有配置 meta-data ${ShellConfig.META_A_SIDE_ACTIVITY}，" +
                        "无处可去，直接结束。",
                )
            } else {
                startActivity(aSide)
            }
            // 不留在返回栈里：用户从 A 面按返回不该又回到这个空壳。
            finish()
            overridePendingTransition(0, 0)
            return
        }

        current = this

        val config = ShellCore.config()
        // eventWebReady 每次页面加载只发一次。WebView 是预加载的、或者这个 Activity 是
        // 被系统回收后重建的，那一条早就发过了，不会再来 —— 这时还撑着 splash 就只能
        // 干等到上限。
        splashUp = !ShellCore.isWebReady()
        splashDeadlineAtMs = SystemClock.uptimeMillis() + config.splashTimeoutMs
        // §9.6 收到 eventWebReady 后立即撤，不要用固定时长定时器；
        // 但 eventWebReady 可能永远不来（内核过低的不兼容页、脚本加载失败的重试页），
        // 所以额外给一个上限兜底。
        splash.setKeepOnScreenCondition { splashUp && SystemClock.uptimeMillis() < splashDeadlineAtMs }
        if (splashUp) {
            splashTimeoutTask = Runnable {
                if (splashUp) {
                    splashUp = false
                    ShellCore.notifySplashDismissed(ShellEventType.SPLASH_TIMED_OUT)
                    Log.w(TAG, "splash 到达 ${config.splashTimeoutMs}ms 上限，强制撤除（§9.6）")
                }
            }
            main.postDelayed(splashTimeoutTask!!, config.splashTimeoutMs)
        }

        container = FrameLayout(this).apply {
            // §8.4 体验与性能 3：背景色与首屏一致，边缘不闪黑。
            setBackgroundColor(config.backgroundColorArgb)
        }
        // §9.4 把 systemBars、ime、displayCutout 的 insets 转成 padding 并 CONSUMED，
        // 不让 insets 再传进 WebView —— 否则页面读到的 env(safe-area-inset-*) 不为 0，
        // 顶部和底部各多一段空白。
        ViewCompat.setOnApplyWindowInsetsListener(container) { view, insets ->
            val i = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or
                    WindowInsetsCompat.Type.ime() or
                    WindowInsetsCompat.Type.displayCutout(),
            )
            view.setPadding(i.left, i.top, i.right, i.bottom)
            WindowInsetsCompat.CONSUMED
        }
        setContentView(container)

        // §7.3 ActivityResultLauncher 必须在到达 STARTED 之前注册完。
        picker = PhotoPickerDelegate(this)

        ImWebViewHolder.attachContext(this)
        attachWebView(ImWebViewHolder.get(this, config))
        ImWebViewHolder.host = this
        // 预加载阶段首屏就加载失败的话，那时没有容器，重试页现在补上。
        ShellCore.onHostAttached(this)

        // §9.1 返回键先回退 Web 的历史。直接 finish() 会导致用户在会话里按返回就退出整个 App。
        // 用 OnBackPressedDispatcher 注册，Android 14 以上的返回手势才有预览动画并走同一套逻辑
        // （§8.4 体验与性能 7，Manifest 里还要 android:enableOnBackInvokedCallback="true"）。
        onBackPressedDispatcher.addCallback(this) {
            when {
                fullscreenView != null -> fullscreenCallback?.onCustomViewHidden()
                ImWebViewHolder.current()?.canGoBack() == true -> ImWebViewHolder.current()?.goBack()
                // §10.6 栈底退到后台，不销毁 WebView。也不调 clearHistory()（§9.1）。
                else -> moveTaskToBack(true)
            }
        }

        if (config.entryUrl.isBlank()) {
            showErrorPage("入口地址未配置（§2.1）")
        }

        maybeWarnOutdatedKernel()
    }

    /**
     * §11.7 内核版本引导。
     *
     * Android 的 WebView 是可独立更新的系统组件，老设备上可能停留在很旧的版本。
     * 低于 §8.1 的下限（92）时**一次性**提示，允许忽略，**不要阻断启动** ——
     * 所以这里既不挡页面加载，也不重复弹。
     */
    private fun maybeWarnOutdatedKernel() {
        if (ShellConfig.kernelWarned(this)) return
        val info = ShellCore.kernelInfo()
        if (info.verdict != KernelVerdict.BELOW_MINIMUM) return
        ShellConfig.markKernelWarned(this)
        // 页面照常加载，提示只是盖在上面的一层。
        AlertDialog.Builder(this)
            .setMessage(R.string.ssg_shell_kernel_outdated)
            .setPositiveButton(R.string.ssg_shell_kernel_update) { _, _ ->
                openWebViewUpdatePage(info.packageName)
            }
            .setNegativeButton(R.string.ssg_shell_kernel_ignore, null)
            .setCancelable(true)
            .show()
    }

    private fun openWebViewUpdatePage(packageName: String) {
        val target = packageName.ifBlank { "com.google.android.webview" }
        // 先试应用商店的详情页，没有商店时退到网页版。
        val market = Intent(Intent.ACTION_VIEW, "market://details?id=$target".toUri())
        if (openExternalIntent(market)) return
        openExternal("https://play.google.com/store/apps/details?id=$target")
    }

    private fun openExternalIntent(intent: Intent): Boolean =
        runCatching { startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true }
            .getOrDefault(false)

    /** §5.3 singleTask：通知点击时复用已在栈里的实例，深链从这里进来。 */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun onStart() {
        super.onStart()
        if (isFinishing) return
        ImWebViewHolder.attachContext(this)
        // §10.2 WebView 真的可见了：ShellCore 据此翻 visibilitychange 并调 onForeground()。
        ShellCore.setImRunning(true)
        // §5 的推送绑定接在 Dart 上。这个 Activity 是冷启动第一个时没有引擎在跑；
        // 宿主的 FlutterActivity 销毁后也可能一个都不剩。每次回到前台确认一遍，
        // 排在首帧之后去起，不跟首屏抢主线程。已经有引擎时是空操作。
        container.post { ShellCore.ensureDartEngine() }
    }

    override fun onStop() {
        ShellCore.setImRunning(false)
        super.onStop()
    }

    override fun onDestroy() {
        if (current === this) current = null
        splashTimeoutTask?.let { main.removeCallbacks(it) }
        splashTimeoutTask = null
        if (ImWebViewHolder.host === this) ImWebViewHolder.host = null
        picker?.dispose()
        picker = null
        pendingAudio?.deny()
        pendingAudio = null
        // §10.6 只取下，不销毁：重建 WebView = 重新加载整个 Web = 重建长连接 + 重拉历史。
        ImWebViewHolder.current()?.let { (it.parent as? ViewGroup)?.removeView(it) }
        ImWebViewHolder.detachContext(applicationContext)
        super.onDestroy()
    }

    private fun attachWebView(web: WebView) {
        (web.parent as? ViewGroup)?.takeIf { it !== container }?.removeView(web)
        if (web.parent === container) return
        container.addView(
            web,
            0,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
    }

    // ------------------------------------------------- ShellWebViewHost

    override fun openPhotoPicker(
        params: WebChromeClient.FileChooserParams,
        callback: ValueCallback<Array<Uri>?>,
    ): Boolean = picker?.launch(params, callback) ?: false

    /**
     * §7.1 / §6.2 麦克风：由 `getUserMedia` 触发，原生在授权回调里**再**向系统申请。
     * 启动阶段一律不申请。
     */
    override fun requestAudioPermission(request: PermissionRequest) {
        val wanted = request.resources
            .filter { it == PermissionRequest.RESOURCE_AUDIO_CAPTURE }
            .toTypedArray()
        if (wanted.isEmpty()) {
            // Web 只用麦克风（§6.1 没有音视频通话），别的一律不给。
            request.deny()
            return
        }
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            request.grant(wanted)
            return
        }
        pendingAudio?.deny()
        pendingAudio = request
        audioRequestedAtMs = SystemClock.elapsedRealtime()
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            REQ_AUDIO,
        )
    }

    /** §7.1 不实现会残留弹窗。 */
    override fun cancelPermissionRequest(request: PermissionRequest) {
        if (pendingAudio === request) {
            pendingAudio = null
        }
    }

    @Deprecated("ComponentActivity 已标记废弃，但 WebView 的麦克风授权只能走这条回调")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (PermissionCoordinator.onRequestPermissionsResult(
                this,
                requestCode,
                permissions,
                grantResults,
            )
        ) {
            return
        }
        if (requestCode != REQ_AUDIO) return
        val request = pendingAudio ?: return
        pendingAudio = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (granted) {
            request.grant(arrayOf(PermissionRequest.RESOURCE_AUDIO_CAPTURE))
        } else {
            request.deny()
            // §6.2 / §12.3「语音被拒后」：Web 弹提示，去系统设置的二次引导由原生负责。
            // 宿主的 Flutter 界面盖不到这个 Activity 上面，所以只能在这里给。
            // 只在「已经永久拒绝」时给：系统没弹框、几乎立刻就回了拒绝。用户刚在系统框里
            // 点了拒绝的那一次不追着弹。
            val answeredWithoutPrompt =
                SystemClock.elapsedRealtime() - audioRequestedAtMs < AUTO_DENY_WINDOW_MS
            val canAskAgain = ActivityCompat.shouldShowRequestPermissionRationale(
                this,
                Manifest.permission.RECORD_AUDIO,
            )
            if (answeredWithoutPrompt && !canAskAgain) showMicrophoneSettingsGuide()
        }
    }

    private fun showMicrophoneSettingsGuide() {
        if (isFinishing || isDestroyed) return
        AlertDialog.Builder(this)
            .setMessage(R.string.ssg_shell_mic_denied)
            .setPositiveButton(R.string.ssg_shell_open_settings) { _, _ ->
                PermissionCoordinator.openAppSettings(this)
            }
            .setNegativeButton(R.string.ssg_shell_cancel, null)
            .show()
    }

    /** §7.1 视频全屏。 */
    override fun showCustomView(view: View, callback: WebChromeClient.CustomViewCallback) {
        if (fullscreenView != null) {
            callback.onCustomViewHidden()
            return
        }
        fullscreenView = view
        fullscreenCallback = callback
        ImWebViewHolder.current()?.visibility = View.GONE
        view.setBackgroundColor(Color.BLACK)
        container.addView(
            view,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
    }

    override fun hideCustomView() {
        val view = fullscreenView ?: return
        container.removeView(view)
        fullscreenView = null
        fullscreenCallback = null
        ImWebViewHolder.current()?.visibility = View.VISIBLE
    }

    /** §7.1 外链、`tel:`、`mailto:` 交给系统，不然用户出不来。 */
    override fun openExternal(url: String): Boolean {
        val uri = runCatching { Uri.parse(url) }.getOrNull() ?: return false
        val intent = Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return runCatching { startActivity(intent); true }
            .onFailure { Log.w(TAG, "没有应用能打开 $url", it) }
            .getOrDefault(false)
    }

    /**
     * §7.1 `onCreateWindow` → 行为对齐 iOS 的 `createWebViewWith`（§7.2）：
     * 外链走系统浏览器，同源地址在**当前**实例里加载（§10.5 只开一个 WebView 实例）。
     */
    override fun openNewWindow(url: String?): Boolean {
        val target = url?.takeIf { it.isNotBlank() } ?: return false
        val uri = runCatching { Uri.parse(target) }.getOrNull() ?: return false
        val entry = ShellCore.config().entryHost()?.lowercase()
        val host = uri.host?.lowercase()
        val internal = entry != null && host != null && (host == entry || host.endsWith(".$entry"))
        if (internal) {
            ImWebViewHolder.current()?.loadUrl(target)
            return true
        }
        return openExternal(target)
    }

    /** §9.6 首屏加载失败接管为原生重试页，不要露出 WebView 默认错误页。 */
    override fun showErrorPage(message: String?) {
        // 页面已经画出来之后的子资源失败不该盖一层错误页，调用方（§7.1）只在主框架失败时调。
        errorView?.let { existing ->
            (existing.findViewById<View>(ID_ERROR_BODY) as? TextView)?.text =
                message ?: getString(R.string.ssg_shell_error_body)
            return
        }
        val view = buildErrorPage(message)
        errorView = view
        container.addView(
            view,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        // 错误页顶上来之后 splash 就该撤了，不然用户只看到启动图，不知道发生了什么。
        dismissSplash(ShellEventType.LOAD_FAILED)
    }

    override fun hideErrorPage() {
        val view = errorView ?: return
        errorView = null
        container.removeView(view)
    }

    /** §9.6 收到 `eventWebReady` 后立即撤 splash。 */
    override fun dismissSplash(reason: ShellEventType) {
        if (!splashUp) return
        splashUp = false
        splashTimeoutTask?.let { main.removeCallbacks(it) }
        splashTimeoutTask = null
        ShellCore.notifySplashDismissed(reason)
    }

    /** §11.2.3 WebView 实例被换掉，重新挂上新实例。 */
    override fun onWebViewReplaced(webView: WebView) {
        hideErrorPage()
        hideCustomView()
        ImWebViewHolder.attachContext(this)
        attachWebView(webView)
    }

    // ------------------------------------------------------------ 错误页

    private fun buildErrorPage(message: String?): View {
        val pad = dp(24f)
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(ShellCore.config().backgroundColorArgb)
            setPadding(pad, pad, pad, pad)
            // 盖在 WebView 上面，别让下面的点击穿过去。
            isClickable = true

            addView(
                TextView(context).apply {
                    text = getString(R.string.ssg_shell_error_title)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
                    setTextColor(0xFF1A1A1A.toInt())
                    gravity = Gravity.CENTER
                },
            )
            addView(
                TextView(context).apply {
                    id = ID_ERROR_BODY
                    text = message ?: getString(R.string.ssg_shell_error_body)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                    setTextColor(0xFF8A8A8E.toInt())
                    gravity = Gravity.CENTER
                    setPadding(0, dp(8f), 0, dp(20f))
                },
            )
            addView(
                Button(context).apply {
                    text = getString(R.string.ssg_shell_error_retry)
                    setOnClickListener {
                        hideErrorPage()
                        // §8.3 资源加载失败时的兜底只做 reload，不要顺手清缓存。
                        val web = ImWebViewHolder.current()
                        val url = web?.url
                        if (web != null && !url.isNullOrBlank() && url != "about:blank") {
                            web.reload()
                        } else {
                            web?.loadUrl(ShellCore.config().resolvedUrl())
                        }
                    }
                },
            )
        }
    }

    private fun dp(value: Float): Int =
        (value * resources.displayMetrics.density + 0.5f).toInt()

    internal companion object {
        private const val TAG = "SsgShell"
        private const val REQ_AUDIO = 0x55A2

        /** 系统真的弹了框的话，用户不可能在这么短的时间里答完。 */
        private const val AUTO_DENY_WINDOW_MS = 800L
        private val ID_ERROR_BODY = View.generateViewId()

        @Volatile
        private var current: ImActivity? = null

        /** [ShellCore.closeIm]。按 §10.6 只结束 Activity，不碰 WebView 实例。 */
        fun finishCurrent() {
            current?.finish()
        }

        fun isRunning(): Boolean = current != null
    }
}
