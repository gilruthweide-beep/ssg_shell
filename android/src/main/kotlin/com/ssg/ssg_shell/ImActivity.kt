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
 * §8.4 Native Activity hosting the IM WebView.
 *
 * The WebView belongs to the application-level [ImWebViewHolder], not this Activity.
 * This Activity attaches/detaches it and supplies Activity-dependent [ShellWebViewHost] operations:
 * photo selection, microphone permission, fullscreen video, external links, and error UI.
 *
 * The specification allows it to be the first Activity on a cold start (§8.4 Performance 2):
 * `installSplashScreen()` and `setKeepOnScreenCondition` retain the system splash until
 * `eventWebReady`, without introducing another loading screen (§9.6).
 */
internal class ImActivity : ComponentActivity(), ShellWebViewHost {

    private lateinit var container: FrameLayout

    private val main = Handler(Looper.getMainLooper())

    /** §9.6 Keep the splash until eventWebReady or the maximum duration. */
    private var splashUp = true

    /** setKeepOnScreenCondition runs each frame; use a deadline timestamp instead of another state flag. */
    private var splashDeadlineAtMs = 0L
    private var splashTimeoutTask: Runnable? = null

    private var picker: PhotoPickerDelegate? = null

    private var errorView: View? = null

    /** §7.1 Fullscreen video. */
    private var fullscreenView: View? = null
    private var fullscreenCallback: WebChromeClient.CustomViewCallback? = null

    /** §7.1 Microphone request pending from onPermissionRequest. */
    private var pendingAudio: PermissionRequest? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // §9.6 Install before super.onCreate; otherwise the first frame already uses postSplashScreenTheme.
        val splash = installSplashScreen()
        super.onCreate(savedInstanceState)

        // Normally androidx.startup initializes the shell before Application.onCreate (see
        // ShellStartupInitializer). This call handles hosts that removed the provider
        // with tools:node="remove" while using this Activity as the cold-start entry point.
        ShellStartupInitializer.ensure(this)

        // §8.4 Performance 2: redirect to A side and finish when B side is disabled.
        // Read only the local cache, as required by §9.6,
        // so selecting the application side never waits for Dart or shows a loading screen.
        if (!ShellCore.isBSideEnabled()) {
            val aSide = ShellCore.aSideIntent()
            if (aSide == null) {
                Log.e(
                    TAG,
                    "B side is disabled and metadata ${ShellConfig.META_A_SIDE_ACTIVITY} is missing;" +
                        " no destination is available, so finish this Activity.",
                )
            } else {
                startActivity(aSide)
            }
            // Remove this empty container from the back stack so Back on A side does not reopen it.
            finish()
            overridePendingTransition(0, 0)
            return
        }

        current = this

        val config = ShellCore.config()
        // eventWebReady fires only once per page load. If the WebView was preloaded, or this Activity was
        // recreated after the system reclaimed it, that event was sent long ago and will not come again; keeping the splash up
        // now would just wait until the limit.
        splashUp = !ShellCore.isWebReady()
        splashDeadlineAtMs = SystemClock.uptimeMillis() + config.splashTimeoutMs
        // §9.6 Remove the splash immediately after eventWebReady instead of using a fixed delay;
        // eventWebReady may never arrive on an unsupported engine or failed script-loading page,
        // so retain a maximum-duration fallback.
        splash.setKeepOnScreenCondition { splashUp && SystemClock.uptimeMillis() < splashDeadlineAtMs }
        if (splashUp) {
            splashTimeoutTask = Runnable {
                if (splashUp) {
                    splashUp = false
                    ShellCore.notifySplashDismissed(ShellEventType.SPLASH_TIMED_OUT)
                    Log.w(TAG, "Splash reached its ${config.splashTimeoutMs}ms limit; removing it (§9.6)")
                }
            }
            main.postDelayed(splashTimeoutTask!!, config.splashTimeoutMs)
        }

        container = FrameLayout(this).apply {
            // §8.4 Performance 3: match the first-screen background to avoid dark flashes at the edges.
            setBackgroundColor(config.backgroundColorArgb)
        }
        // §9.4 Convert systemBars, ime, and displayCutout insets to padding and consume them.
        // Do not forward them to the WebView, which would otherwise read nonzero env(safe-area-inset-*) values
        // and add duplicate spacing above and below its content.
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

        // §7.3 Register ActivityResultLauncher before the Activity reaches STARTED.
        picker = PhotoPickerDelegate(this)

        ImWebViewHolder.attachContext(this)
        attachWebView(ImWebViewHolder.get(this, config))
        ImWebViewHolder.host = this
        // If the initial page failed to load during preload, there was no container then; show the retry page now.
        ShellCore.onHostAttached(this)

        // §9.1 Back navigates Web history first; immediately finishing would exit the application from a conversation.
        // Register through OnBackPressedDispatcher so Android 14+ predictive gestures show previews and use the same navigation logic
        // (§8.4 Performance 7 also requires android:enableOnBackInvokedCallback="true" in the Manifest).
        onBackPressedDispatcher.addCallback(this) {
            when {
                fullscreenView != null -> fullscreenCallback?.onCustomViewHidden()
                ImWebViewHolder.current()?.canGoBack() == true -> ImWebViewHolder.current()?.goBack()
                // §10.6 Move the root task to the background without destroying the WebView or clearing history (§9.1).
                else -> moveTaskToBack(true)
            }
        }

        if (config.entryUrl.isBlank()) {
            showErrorPage("Landing URL is not configured (§2.1)")
        }

        maybeWarnOutdatedKernel()
    }

    /**
     * §11.7 Engine update guidance.
     *
     * Android WebView is an independently updatable system component that may be outdated on older devices.
     * Below the §8.1 minimum (92), show a dismissible prompt **once** without blocking startup.
     * Keep page loading active and avoid repeated prompts.
     */
    private fun maybeWarnOutdatedKernel() {
        if (ShellConfig.kernelWarned(this)) return
        val info = ShellCore.kernelInfo()
        if (info.verdict != KernelVerdict.BELOW_MINIMUM) return
        ShellConfig.markKernelWarned(this)
        // The page continues loading underneath the update prompt.
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
        // Try the application store detail page first, then fall back to its website.
        val market = Intent(Intent.ACTION_VIEW, "market://details?id=$target".toUri())
        if (openExternalIntent(market)) return
        openExternal("https://play.google.com/store/apps/details?id=$target")
    }

    private fun openExternalIntent(intent: Intent): Boolean =
        runCatching { startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true }
            .getOrDefault(false)

    /** §5.3 singleTask reuses the existing Activity for notification clicks; deep links enter here. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun onStart() {
        super.onStart()
        if (isFinishing) return
        ImWebViewHolder.attachContext(this)
        // §10.2 The WebView is actually visible; ShellCore updates visibilitychange and calls onForeground().
        ShellCore.setImRunning(true)
        // §5 push binding lives in Dart. When this Activity is the first one on cold start, no engine is running;
        // there may also be none left after the host's FlutterActivity is destroyed. Check again on every return to the foreground,
        // starting it after the first frame so it does not compete with the first screen for the main thread. No-op when an engine already exists.
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
        // §10.6 Detach without destroying: recreation reloads the entire Web app, reconnects its socket, and fetches history again.
        // Only detach what this instance hosts. An instance that redirected to A side finishes before attaching anything,
        // but the system may destroy it only after a newer ImActivity attached the shared WebView (for example when the
        // host turns B side on during the same launch); removing the WebView then would leave that container blank.
        if (::container.isInitialized) {
            ImWebViewHolder.current()?.takeIf { it.parent === container }?.let { container.removeView(it) }
        }
        ImWebViewHolder.detachContext(this)
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
     * §7.1 / §6.2 `getUserMedia` triggers microphone access; request system permission from its native callback.
     * Never request it at startup.
     */
    override fun requestAudioPermission(request: PermissionRequest) {
        val wanted = request.resources
            .filter { it == PermissionRequest.RESOURCE_AUDIO_CAPTURE }
            .toTypedArray()
        if (wanted.isEmpty()) {
            // §6.1 The Web application uses only microphone capture, not audio/video calls; reject other requested resources.
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
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            REQ_AUDIO,
        )
    }

    /** §7.1 Clean up permission UI to avoid leaving a dialog open. */
    override fun cancelPermissionRequest(request: PermissionRequest) {
        if (pendingAudio === request) {
            pendingAudio = null
        }
    }

    @Deprecated("Deprecated by ComponentActivity, but required for WebView microphone permission results")
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
            // §6.2 / §12.3 After a microphone denial, the Web application shows a notice and native code
            // offers Settings; the host's Flutter UI cannot cover this Activity.
            // Local patch: offer it after every denial, not only a permanent one. Chromium can cache
            // the origin denial and skip later native callbacks, so this may be the last chance.
            // An empty result means the prompt was interrupted, not that the user decided.
            if (grantResults.isNotEmpty()) showMicrophoneSettingsGuide()
        }
    }

    private fun showMicrophoneSettingsGuide() {
        if (isFinishing || isDestroyed) return
        AlertDialog.Builder(this)
            .setTitle(R.string.ssg_shell_mic_denied_title)
            .setMessage(R.string.ssg_shell_mic_denied)
            .setPositiveButton(R.string.ssg_shell_open_settings) { _, _ ->
                PermissionCoordinator.openAppSettings(this)
            }
            .setNegativeButton(R.string.ssg_shell_cancel, null)
            .show()
    }

    /** §7.1 Video fullscreen. */
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

    /** §7.1 Delegate external links, tel:, and mailto: to the system instead of trapping navigation. */
    override fun openExternal(url: String): Boolean {
        val uri = runCatching { Uri.parse(url) }.getOrNull() ?: return false
        val intent = Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return runCatching { startActivity(intent); true }
            .onFailure { Log.w(TAG, "No application can open $url", it) }
            .getOrDefault(false)
    }

    /**
     * §7.1 `onCreateWindow` matches the iOS `createWebViewWith` behavior (§7.2):
     * open external links in the system browser and same-origin URLs in the current WebView (§10.5).
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

    /** §9.6 Replace initial-load failures with a native retry screen instead of the default WebView error UI. */
    override fun showErrorPage(message: String?) {
        // Subresource failures after rendering must not cover the page; §7.1 callers invoke this only for main-frame failures.
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
        // Remove the splash when displaying an error page so the user can see what happened.
        dismissSplash(ShellEventType.LOAD_FAILED)
    }

    override fun hideErrorPage() {
        val view = errorView ?: return
        errorView = null
        container.removeView(view)
    }

    /** §9.6 Remove the splash immediately after `eventWebReady`. */
    override fun dismissSplash(reason: ShellEventType) {
        if (!splashUp) return
        splashUp = false
        splashTimeoutTask?.let { main.removeCallbacks(it) }
        splashTimeoutTask = null
        ShellCore.notifySplashDismissed(reason)
    }

    /** §11.2.3 Reattach the replacement WebView after recreation. */
    override fun onWebViewReplaced(webView: WebView) {
        hideErrorPage()
        hideCustomView()
        ImWebViewHolder.attachContext(this)
        attachWebView(webView)
    }

    // ------------------------------------------------------------ Error screen

    private fun buildErrorPage(message: String?): View {
        val pad = dp(24f)
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(ShellCore.config().backgroundColorArgb)
            setPadding(pad, pad, pad, pad)
            // Cover the WebView and consume touches instead of passing them through.
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
                        // §8.3 Retry resource-loading failures by reloading only; preserve caches.
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
        private val ID_ERROR_BODY = View.generateViewId()

        @Volatile
        private var current: ImActivity? = null

        /** [ShellCore.closeIm] finishes only the Activity and preserves the WebView instance (§10.6). */
        fun finishCurrent() {
            current?.finish()
        }

        fun isRunning(): Boolean = current != null
    }
}
