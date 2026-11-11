package com.ssg.ssg_shell

import android.app.Activity
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Process-level shell coordinator, independent of the Flutter engine lifetime.
 *
 * This state does not belong to `SsgShellPlugin`: §8.4 Performance 2 allows `ImActivity` to be
 * the first cold-start Activity, before Flutter starts, while §11.2 liveness monitoring, §11.1 heartbeat,
 * and §10.4 network notifications must already be running.
 */
internal object ShellCore {

    private const val TAG = "SsgShell"

    private val main = Handler(Looper.getMainLooper())

    private lateinit var appContext: Context

    @Volatile
    private var config: ShellConfig = ShellConfig(
        entryUrl = "",
        channelCode = "",
        shellVersion = "0.0.0",
        bSideEnabled = false,
    )

    /**
     * Dart-side callback channels, one per engine with the plugin attached. When there are none, every emit is skipped.
     *
     * When there is more than one: besides the headless engine started by [ensureDartEngine], the host's FlutterActivity
     * created another one itself. Both must receive events, and destroying the later one must not take the earlier channel with it.
     */
    private val dartApis = CopyOnWriteArrayList<SsgShellFlutterApi>()

    private var headlessEngineRequested = false

    private val console = ConsoleLogBuffer()
    private val gate = NotificationGate()

    private val watchdog = Watchdog(
        config = { config },
        callWeb = { ImWebViewHolder.callWeb(it) },
        reload = { ImWebViewHolder.reload() },
        recreate = { recreateWebView() },
        emit = { type, message, extra -> emit(type, message, extra) },
    )

    private var network: NetworkMonitor? = null

    @Volatile
    var appInForeground: Boolean = false
        private set

    /** Whether the IM container ([ImActivity]) is attached to the WebView and visible. */
    @Volatile
    var imRunning: Boolean = false
        private set

    /** Last calculated WebView visibility, used to notify the Web application only on changes. */
    private var webVisible: Boolean = false

    @Volatile
    private var webReady: Boolean = false

    /**
     * Keep the latest of each stateful Web event. Dart cannot receive events that happened before it came online,
     * and `login` is sent only once per uid (§3.1); if lost, OneSignal is never bound (§5.2).
     * [replaySticky] replays them when Dart calls `initialize()`.
     */
    private var stickyWebReady: WebEvent? = null
    private var stickyIdentity: WebEvent? = null
    private var stickyUnread: WebEvent? = null
    private var stickyChatOpen: WebEvent? = null

    /**
     * When the initial page fails to load with no container attached (preload phase), there is nowhere to show the retry page.
     * Record it and apply it when a container attaches ([onHostAttached]).
     */
    private var loadFailed: Boolean = false
    private var loadFailedMessage: String? = null

    private var reportedChannelCode: String = ""
    private var lastWebReadyAtMs: Long? = null

    /** §5.3 Queue cold-start notification parameters until the Web application emits webReady. */
    private var pendingOpenChat: OpenChatRequest? = null

    @Volatile
    private var injectionOk: Boolean = false

    /** §6.2 Allow notification permission requests only after `eventLogin`. */
    @Volatile
    private var loginSeen: Boolean = false

    private var started = false

    // -------------------------------------------------------------- Initialization

    /** Called idempotently by [ShellStartupInitializer] at process startup or by [SsgShellPlugin]. */
    fun attach(context: Context) {
        if (started) return
        started = true
        appContext = context.applicationContext
        config = ShellConfig.fromDisk(appContext)
        console.capacity = config.consoleBufferSize

        // §4 / §10.2 Track process-level foreground state independently of the host Activity, so switching Flutter pages and ImActivity
        // does not look like a background-to-foreground transition.
        main.post {
            ProcessLifecycleOwner.get().lifecycle.addObserver(
                object : DefaultLifecycleObserver {
                    override fun onStart(owner: LifecycleOwner) = setAppForeground(true)
                    override fun onStop(owner: LifecycleOwner) = setAppForeground(false)
                },
            )
        }

        // §11.4 Evaluate Application.onTrimMemory directly and forward genuine warnings;
        // do not route them through Flutter's didHaveMemoryPressure.
        appContext.registerComponentCallbacks(object : ComponentCallbacks2 {
            override fun onTrimMemory(level: Int) = this@ShellCore.onTrimMemory(level)
            override fun onConfigurationChanged(newConfig: Configuration) = Unit
            override fun onLowMemory() = this@ShellCore.onTrimMemory(
                ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL,
            )
        })

        network = NetworkMonitor(
            context = appContext,
            debounceMs = { config.networkDebounceMs },
            onAvailable = { type -> deliverNetwork(type) },
        ).also { it.start() }

        // §11.7 Below engine version 92, show dismissible update guidance once without blocking startup.
        kernelInfo().let { info ->
            if (info.verdict == KernelVerdict.BELOW_MINIMUM) {
                Log.w(TAG, "WebView engine ${info.versionName} is below ${config.minKernelVersion} (§8.1 / §11.7)")
            }
        }
    }

    fun addDartApi(api: SsgShellFlutterApi) {
        dartApis.addIfAbsent(api)
    }

    fun removeDartApi(api: SsgShellFlutterApi) {
        dartApis.remove(api)
    }

    /**
     * When Dart calls `initialize()`, replay the stateful events it missed before coming online. Must be called on the main thread
     * before `initialize` returns; Dart relies on the "events first, return value second" order to catch them.
     */
    fun replaySticky(api: SsgShellFlutterApi) {
        listOfNotNull(stickyWebReady, stickyIdentity, stickyUnread, stickyChatOpen)
            .forEach { api.onWebEvent(it) {} }
    }

    /**
     * §5 OneSignal binding, requesting notification permission after login, and notification-click deep links all live in Dart (see README).
     * When `ImActivity` is the first Activity on cold start (§8.4 Performance 2) there is no FlutterActivity,
     * so no engine starts on its own and none of this runs. Start a headless engine here to run the host's `main()`.
     *
     * Does nothing when an engine with the plugin attached already exists. The engine goes into [FlutterEngineCache], and the host's
     * FlutterActivity can reuse it via [SsgShellPlugin.ENGINE_ID] so `main()` does not run twice.
     */
    fun ensureDartEngine() {
        if (dartApis.isNotEmpty() || headlessEngineRequested) return
        headlessEngineRequested = true
        runCatching {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(appContext)
            loader.ensureInitializationCompleteAsync(appContext, null, main) {
                // The host's own pre-warmed engine got there first; no need to start another.
                if (dartApis.isNotEmpty()) return@ensureInitializationCompleteAsync
                runCatching {
                    val engine = FlutterEngine(appContext)
                    engine.dartExecutor.executeDartEntrypoint(
                        DartExecutor.DartEntrypoint.createDefault(),
                    )
                    FlutterEngineCache.getInstance().put(SsgShellPlugin.ENGINE_ID, engine)
                    Log.i(TAG, "No Flutter engine running; started a headless engine to run the Dart entrypoint")
                }.onFailure {
                    headlessEngineRequested = false
                    Log.e(TAG, "Headless Flutter engine failed to start; Dart-side push binding will not take effect", it)
                }
            }
        }.onFailure {
            headlessEngineRequested = false
            Log.e(TAG, "Flutter initialization failed; Dart-side push binding will not take effect", it)
        }
    }

    fun requireContext(): Context = appContext

    fun config(): ShellConfig = config

    // ----------------------------------------------------------- HostApi

    fun initialize(dto: ShellConfigDto): ShellInfo {
        val next = ShellConfig.fromDto(appContext, dto)
        if (next.entryUrl != config.entryUrl) reportedChannelCode = ""
        config = next
        console.capacity = next.consoleBufferSize
        // §9.6 Persist configuration so ImActivity can use it directly on the next cold start without Dart.
        ShellConfig.persist(appContext, next)
        return ShellInjection.shellInfo(appContext, next.shellVersion)
    }

    /** §8.4 Performance 1: preload the WebView only when B side is enabled. */
    fun preload() {
        if (!config.bSideEnabled) {
            Log.i(TAG, "B side is disabled; skipping IM preload (§8.4 Performance 1)")
            return
        }
        if (config.entryUrl.isBlank()) {
            Log.w(TAG, "entryUrl is empty; skipping preload")
            return
        }
        main.post { ImWebViewHolder.get(appContext, config) }
    }

    fun openIm() {
        main.post {
            val intent = Intent(appContext, ImActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                // launchMode=singleTask reuses the existing instance and prevents duplicates (§10.5).
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            runCatching { appContext.startActivity(intent) }
                .onFailure { Log.e(TAG, "Unable to open ImActivity", it) }
        }
    }

    fun closeIm() {
        main.post { ImActivity.finishCurrent() }
    }

    fun setBSideEnabled(enabled: Boolean) {
        config = config.copy(bSideEnabled = enabled)
        ShellConfig.persistBSide(appContext, enabled)
    }

    fun isBSideEnabled(): Boolean = config.bSideEnabled

    /**
     * §5.3 Open a conversation.
     *
     * Wait for `eventWebReady`: queue notification parameters while the Web application initializes on a cold start.
     * Deliver once. The Web application waits up to 20 seconds for conversation data; native retries are unnecessary.
     */
    fun openChat(request: OpenChatRequest) {
        if (request.chatId.isBlank()) return
        main.post {
            if (!webReady) {
                pendingOpenChat = request
                Log.i(TAG, "openChat queued until WebReady: chatId=${request.chatId}")
                emit(
                    ShellEventType.DEEP_LINK_QUEUED,
                    "Web is not ready; queued chatId=${request.chatId}",
                    mapOf("chatId" to request.chatId),
                )
                return@post
            }
            deliverOpenChat(request)
        }
    }

    private fun deliverOpenChat(request: OpenChatRequest) {
        val payload = JSONObject().apply {
            // §5.3 Pass chatId as a string.
            put("chatId", request.chatId)
            // Optional messageId accepts a number or a string parseable by Number().
            request.messageId?.takeIf { it.isNotBlank() }?.let { raw ->
                val asNumber = raw.trim().toLongOrNull()
                if (asNumber != null) put("messageId", asNumber) else put("messageId", raw)
            }
        }
        ImWebViewHolder.callWeb("openChat", payload.toString())
        Log.i(TAG, "openChat delivered to Web: chatId=${request.chatId}")
        emit(
            ShellEventType.DEEP_LINK_DELIVERED,
            "Delivered to Web: chatId=${request.chatId}",
            buildMap {
                put("chatId", request.chatId)
                request.messageId?.let { put("messageId", it) }
            },
        )
    }

    /** §5.4 Foreground suppression and §11.3 push-triggered Web connection wakeup. */
    fun handlePushReceived(message: PushMessage): PushDecision {
        val chatId = message.chatId
        val suppress = gate.shouldSuppress(
            chatId = chatId,
            appInForeground = appInForeground && imRunning && config.bSideEnabled,
            enabled = config.suppressForegroundNotifications,
        )

        // §11.3 A foreground push indicates that the Web application missed a message over its persistent connection.
        // Alongside §5.4 notification suppression, call onNetwork once to wake that connection.
        var nudged = false
        if (appInForeground) {
            // Receiving the push confirms connectivity; use other until the monitor marks the network VALIDATED.
            val observed = network?.currentType ?: NetworkType.NONE
            val type = if (observed == NetworkType.NONE) NetworkType.OTHER else observed
            main.post { deliverNetwork(type) }
            nudged = true
        }

        val reason = buildString {
            append(if (appInForeground) "Foreground" else "Background")
            append("; tracked=").append(gate.trackedChatId ?: "-")
            append("; incoming=").append(chatId ?: "-")
            if (suppress) append("; foreground notification suppressed")
            if (nudged) append("; Web connection nudged through onNetwork")
        }
        Log.i(TAG, "handlePushReceived: $reason")

        return PushDecision(
            suppressNotification = suppress,
            nudgedWeb = nudged,
            appInForeground = appInForeground,
            reason = reason,
        )
    }

    /** §5.3 Notification click handling. */
    fun handlePushOpened(message: PushMessage) {
        Log.i(TAG, "handlePushOpened: chatId=${message.chatId ?: "-"}; webReady=$webReady")
        val chatId = message.chatId?.takeIf { it.isNotBlank() }
        if (config.bSideEnabled) openIm()
        if (chatId == null) {
            Log.w(TAG, "Notification click has no chat_id; opening the application only")
            return
        }
        openChat(OpenChatRequest(chatId = chatId, messageId = message.messageId))
    }

    fun nudgeNetwork(type: NetworkType) {
        main.post { deliverNetwork(type) }
    }

    fun reloadWeb() {
        main.post {
            Log.i(TAG, "Manual reload (§11.2)")
            ImWebViewHolder.reload()
        }
    }

    fun recreateWebView() {
        main.post {
            // §11.2.3 **Terminate the renderer before recreation.** All WebViews in one Android application share a renderer;
            // replacing only the view would attach the replacement to the same process blocked by the infinite loop.
            if (ImWebViewHolder.terminateRenderProcess()) {
                // Termination triggers §7.1 onRenderProcessGone, which owns recreation,
                // preventing duplicate WebView instances (§10.5).
                Log.i(TAG, "Renderer terminated; waiting for onRenderProcessGone to recreate the WebView")
                return@post
            }
            Log.w(TAG, "Renderer could not be terminated; replacing the WebView directly (legacy-engine fallback, §11.2.3)")
            doRecreate()
        }
    }

    private fun doRecreate() {
        onPageReset()
        gate.onPageLoadStarted()
        ImWebViewHolder.recreate(appContext, config)
        watchdog.onWebViewRecreated()
        emit(ShellEventType.WEB_VIEW_RECREATED, "WebView instance recreated", emptyMap())
    }

    fun setBadgeCount(count: Int) {
        gate.setBadge(count)
        BadgeApplier.apply(appContext, count)
    }

    fun verifyInjection(onResult: (Boolean) -> Unit) {
        // §1.3 Use the Web application's own verdict. A true result fails regardless of the contents of __SSG_SHELL__.
        val js = "document.documentElement.classList.contains('is-web-browser')"
        main.post {
            ImWebViewHolder.evaluate(js) { raw ->
                val isBrowser = raw?.trim()?.trim('"')
                val ok = isBrowser == "false"
                injectionOk = ok
                emit(
                    ShellEventType.INJECTION_CHECKED,
                    if (ok) "Injection active" else "Injection failed (is-web-browser=$isBrowser); see §1.2",
                    mapOf("isWebBrowser" to (isBrowser ?: "null")),
                )
                onResult(ok)
            }
        }
    }

    fun evaluateJavaScript(script: String, onResult: (Result<String>) -> Unit) {
        // §8.3 Preserve storage. Clearing it logs users out, removes cached messages, downloads media again,
        // loses diagnostic context, and resets the once-per-device eventRegister marker, inflating attribution counts.
        FORBIDDEN_JS.firstOrNull { script.contains(it, ignoreCase = true) }?.let { hit ->
            onResult(
                Result.failure(
                    IllegalArgumentException(
                        "Script contains prohibited storage deletion call $hit; see §8.3. Deletion requires an explicit user action to clear data.",
                    ),
                ),
            )
            return
        }
        main.post {
            ImWebViewHolder.evaluate(script) { raw -> onResult(Result.success(raw.orEmpty())) }
        }
    }

    // ------------------------------------------------------------ Diagnostics

    fun kernelInfo(): KernelInfo {
        val versionName = ShellInjection.webViewVersionName(appContext)
        val major = versionName.substringBefore('.').toIntOrNull() ?: -1
        val verdict = when {
            major < 0 -> KernelVerdict.UNKNOWN
            major < config.minKernelVersion -> KernelVerdict.BELOW_MINIMUM
            major < config.recommendedKernelVersion -> KernelVerdict.BELOW_RECOMMENDED
            else -> KernelVerdict.OK
        }
        return KernelInfo(
            verdict = verdict,
            versionName = versionName,
            majorVersion = major.toLong(),
            packageName = ShellInjection.webViewPackageName(appContext),
        )
    }

    fun diagnostics(): ShellDiagnostics = ShellDiagnostics(
        shellInfo = ShellInjection.shellInfo(appContext, config.shellVersion),
        entryUrl = config.resolvedUrl(),
        currentUrl = ImWebViewHolder.currentUrl(),
        userAgent = ImWebViewHolder.userAgent(),
        channelCode = reportedChannelCode,
        injectionOk = injectionOk && ImWebViewHolder.documentStartInjected,
        imRunning = imRunning,
        appInForeground = appInForeground,
        reloadCount = watchdog.reloadCount.toLong(),
        recreateCount = watchdog.recreateCount.toLong(),
        badgeCount = gate.badgeCount.toLong(),
        kernel = kernelInfo(),
        consoleTail = console.snapshot(),
        lastReloadAtMs = watchdog.lastReloadAtMs,
        lastWebReadyAtMs = lastWebReadyAtMs,
        lastWebAliveAtMs = watchdog.lastAlive(),
        trackedChatId = gate.trackedChatId,
    )

    /** §11.6 Export URL, user agent, engine version, __SSG_SHELL__, last reload time, and recent console entries. */
    fun exportDiagnostics(): String {
        val d = diagnostics()
        val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.ROOT)
        fun time(ms: Long?) = ms?.let { fmt.format(Date(it)) } ?: "-"
        return buildString {
            appendLine("==== SSG Shell diagnostics ====")
            appendLine("Exported at        ${fmt.format(Date())}")
            appendLine("Platform            android")
            appendLine("Bundle ID            ${d.shellInfo.bundleId}")
            appendLine("Shell version          ${d.shellInfo.shellVersion}")
            appendLine("Device model            ${d.shellInfo.deviceModel}")
            appendLine("OS version        ${d.shellInfo.osVersion}")
            appendLine("Engine version        ${d.kernel.versionName} (${d.kernel.verdict}) ${d.kernel.packageName}")
            appendLine("Landing URL        ${d.entryUrl}")
            appendLine("Current URL        ${d.currentUrl}")
            appendLine("UA              ${d.userAgent}")
            appendLine("channelCode     ${d.channelCode.ifEmpty { "(optional; not supplied by Web attribution events)" }}")
            appendLine("Injection check        ${if (d.injectionOk) "Passed shellSrc:inject" else "Failed; see §1.2"}")
            appendLine("IM attached         ${d.imRunning}")
            appendLine("App foreground        ${d.appInForeground}")
            appendLine("Last webReady   ${time(d.lastWebReadyAtMs)}")
            appendLine("Last webAlive   ${time(d.lastWebAliveAtMs)}")
            appendLine("Last reload     ${time(d.lastReloadAtMs)}  Count ${d.reloadCount}")
            appendLine("WebView recreations    ${d.recreateCount} times")
            appendLine("Active chat        ${d.trackedChatId ?: "-"}")
            appendLine("Badge            ${d.badgeCount}")
            appendLine()
            appendLine("---- Last ${d.consoleTail.size} console entries ----")
            appendLine(console.dump())
        }
    }

    // ------------------------------------------------- WebView callbacks

    /** §3.1 Events from [JsBridge] may arrive on the JavaScript thread; dispatch to the main thread. */
    fun onWebEvent(event: WebEvent) {
        main.post { handleWebEvent(event) }
    }

    private fun handleWebEvent(event: WebEvent) {
        // §2.1 The Web application owns channel attribution; diagnostics record events without reading or rewriting the URL.
        if (event.name == WebEventName.REGISTER || event.name == WebEventName.LOGIN ||
            event.name == WebEventName.MESSAGE_SENT) {
            reportedChannelCode = event.params["channelCode"].orEmpty()
        }
        when (event.name) {
            WebEventName.WEB_READY -> {
                webReady = true
                stickyWebReady = event
                lastWebReadyAtMs = event.receivedAtMs
                // §9.6 Remove the splash immediately after eventWebReady rather than waiting a fixed duration.
                ImWebViewHolder.host?.dismissSplash(ShellEventType.SPLASH_DISMISSED)
                // §5.3 Deliver queued cold-start notification parameters once after readiness.
                pendingOpenChat?.let { queued ->
                    pendingOpenChat = null
                    deliverOpenChat(queued)
                }
                // §1.3 Run the injection check when the first screen is visible without requiring a debugger.
                verifyInjection {}
            }

            WebEventName.WEB_ALIVE -> watchdog.onWebAlive()

            WebEventName.CHAT_OPEN -> {
                gate.onChatOpen(event.chatId)
                stickyChatOpen = event.takeIf { gate.trackedChatId != null }
            }

            WebEventName.CHAT_CLOSE -> {
                gate.onChatClose(event.chatId)
                if (gate.trackedChatId == null) stickyChatOpen = null
            }

            WebEventName.UNREAD_COUNT -> {
                stickyUnread = event
                val count = (event.unreadCount ?: 0L).toInt()
                gate.onUnreadCount(count)
                // §5.4 Badge count equals the Web unread total; a count of zero clears it.
                if (config.manageBadge) BadgeApplier.apply(appContext, count)
            }

            // §6.2 Open the notification permission gate only after eventLogin;
            // Dart controls the actual prompt timing so the host can show its own introduction first.
            // An empty uid is not a login: it must not unlock the prompt or bind OneSignal.
            WebEventName.LOGIN -> if (!event.uid.isNullOrBlank()) {
                loginSeen = true
                stickyIdentity = event
            }

            WebEventName.LOGOUT -> {
                loginSeen = false
                // Local patch: keep the logout as the latest identity. A logout that happens
                // before Dart starts must still reach OneSignal.logout(); otherwise the device
                // keeps receiving the previous account's pushes.
                stickyIdentity = event
                stickyChatOpen = null
                // §5.4 The Web application emits unreadCount=0 on logout; let that event clear the badge.
            }

            else -> Unit
        }

        dartApis.forEach { api -> api.onWebEvent(event) { /* Missing Dart listeners are not errors. */ } }
    }

    fun hasLoggedIn(): Boolean = loginSeen

    fun isWebReady(): Boolean = webReady

    /**
     * When a container attaches, apply the state it missed.
     *
     * `eventWebReady` fires only once per page load and will not come again if sent during preload; the splash half
     * is decided by the container reading [isWebReady] itself; this handles the retry page for an initial page load failure (§9.6).
     */
    fun onHostAttached(host: ShellWebViewHost) {
        if (loadFailed) host.showErrorPage(loadFailedMessage)
    }

    /** The page is about to reload (reload, recreation): all state left by the previous page is discarded. */
    private fun onPageReset() {
        webReady = false
        stickyWebReady = null
        stickyChatOpen = null
        loadFailed = false
        loadFailedMessage = null
    }

    fun onPageStarted(url: String?) {
        // §5.4 Page reloads do not emit chatClose; clear the tracked chatId when loading starts.
        gate.onPageLoadStarted()
        onPageReset()
        watchdog.onPageStarted()
        watchdog.onPageLoadStartedExternally()
        ImWebViewHolder.host?.hideErrorPage()
        Log.d(TAG, "onPageStarted $url")
    }

    fun onPageFinished(url: String?) {
        Log.d(TAG, "onPageFinished $url")
    }

    fun onMainFrameLoadFailed(url: String, description: String) {
        Log.w(TAG, "Initial page load failed $url: $description")
        main.post {
            loadFailed = true
            loadFailedMessage = null
            ImWebViewHolder.host?.showErrorPage(null)
            emit(ShellEventType.LOAD_FAILED, description, mapOf("url" to url))
        }
    }

    fun onSslError(primaryError: Int) {
        main.post {
            val message = appContext.getString(R.string.ssg_shell_ssl_body)
            loadFailed = true
            loadFailedMessage = message
            ImWebViewHolder.host?.showErrorPage(message)
            emit(
                ShellEventType.LOAD_FAILED,
                "SSL validation failed (primaryError=$primaryError)",
                mapOf("sslError" to primaryError.toString()),
            )
        }
    }

    fun onRenderProcessGone(crashed: Boolean) {
        main.post {
            emit(
                ShellEventType.RENDER_PROCESS_GONE,
                if (crashed) "Renderer crashed" else "Renderer reclaimed or explicitly terminated",
                mapOf("didCrash" to crashed.toString()),
            )
            // §7.1 The old WebView is unusable; destroy it and load the landing URL in a new instance instead of reloading it.
            doRecreate()
        }
    }

    fun onConsoleMessage(level: ConsoleLevel, message: String, source: String?, line: Long) {
        if (!config.forwardConsole) return
        val record = ConsoleRecord(
            level = level,
            message = message,
            atMs = System.currentTimeMillis(),
            source = source,
            line = line,
        )
        console.add(record)
        // §11.6 Forward Web console output to native logs.
        val tag = "SsgShellWeb"
        when (level) {
            ConsoleLevel.ERROR -> Log.e(tag, message)
            ConsoleLevel.WARNING -> Log.w(tag, message)
            ConsoleLevel.DEBUG -> Log.d(tag, message)
            else -> Log.i(tag, message)
        }
        val event = ShellEvent(
            type = ShellEventType.CONSOLE_MESSAGE,
            atMs = record.atMs,
            extra = emptyMap(),
            message = message,
            console = record,
        )
        main.post { dartApis.forEach { api -> api.onShellEvent(event) {} } }
    }

    /**
     * §11.4 Memory warning.
     *
     * Invoke only for `TRIM_MEMORY_RUNNING_LOW` or `TRIM_MEMORY_RUNNING_CRITICAL`.
     * **Do not use `level >= TRIM_MEMORY_RUNNING_LOW`**: background entry always emits
     * `TRIM_MEMORY_UI_HIDDEN` (20), which exceeds `RUNNING_LOW` (10) but is not a memory warning.
     */
    fun onTrimMemory(level: Int) {
        if (level != ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW &&
            level != ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL
        ) {
            return
        }
        main.post {
            ImWebViewHolder.callWeb("onMemoryWarning")
            emit(
                ShellEventType.MEMORY_WARNING,
                "onTrimMemory(level=$level)",
                mapOf("level" to level.toString()),
            )
        }
    }

    // ------------------------------------------------------- Lifecycle

    private fun setAppForeground(foreground: Boolean) {
        if (appInForeground == foreground) return
        appInForeground = foreground
        updateWebVisibility()
    }

    fun setImRunning(running: Boolean) {
        if (imRunning == running) return
        imRunning = running
        emit(
            if (running) ShellEventType.IM_OPENED else ShellEventType.IM_CLOSED,
            null,
            emptyMap(),
        )
        updateWebVisibility()
    }

    /**
     * §10.2 Foreground signaling.
     *
     * Use actual WebView visibility rather than application foreground state. Switching IM and Flutter A side
     * keeps the application in the foreground while the WebView has called `onPause()` and `document.hidden` is true,
     * and eventWebAlive stops. Keeping §11.2 timing active would falsely detect a timeout after 60 seconds.
     */
    private fun updateWebVisibility() {
        val visible = appInForeground && imRunning
        if (visible == webVisible) return
        webVisible = visible
        if (visible) {
            // §10.2.2 Call onResume() first to update document.hidden and let visibilitychange provide
            // a second foreground signal independent of injection.
            ImWebViewHolder.onResumeWeb()
            // §10.2.1 Call onForeground() on every foreground transition, including unlocks, returning from background tasks,
            // and notification clicks. With injection active, returning after more than 1.5 seconds reconnects immediately.
            ImWebViewHolder.callWeb("onForeground")
            watchdog.onForeground()
            emit(ShellEventType.FOREGROUND, null, emptyMap())
        } else {
            ImWebViewHolder.callWeb("onBackground")
            // §10.3 Call onPause() to pause rendering and visibility, but preserve timers by avoiding pauseTimers().
            ImWebViewHolder.onPauseWeb()
            watchdog.onBackground()
            emit(ShellEventType.BACKGROUND, null, emptyMap())
        }
    }

    private fun deliverNetwork(type: NetworkType) {
        // §4 Do not report disconnection; none would be ignored.
        if (type == NetworkType.NONE) return
        val wire = when (type) {
            NetworkType.WIFI -> "wifi"
            NetworkType.CELLULAR -> "cellular"
            NetworkType.ETHERNET -> "ethernet"
            else -> "other"
        }
        ImWebViewHolder.callWeb("onNetwork", "'$wire'")
        emit(ShellEventType.NETWORK_CHANGED, wire, mapOf("type" to wire), type)
    }

    fun currentNetworkType(): NetworkType = network?.currentType ?: NetworkType.NONE

    // ------------------------------------------------------------ Utilities

    private fun emit(
        type: ShellEventType,
        message: String?,
        extra: Map<String, String>,
        networkType: NetworkType? = null,
    ) {
        val event = ShellEvent(
            type = type,
            atMs = System.currentTimeMillis(),
            extra = extra,
            message = message,
            network = networkType,
        )
        if (Looper.myLooper() == Looper.getMainLooper()) {
            dartApis.forEach { api -> api.onShellEvent(event) {} }
        } else {
            main.post { dartApis.forEach { api -> api.onShellEvent(event) {} } }
        }
    }

    fun notifySplashDismissed(reason: ShellEventType) {
        emit(reason, null, emptyMap())
    }

    /** For [ImActivity]: resolve the A-side Activity to redirect and finish when B side is disabled (§8.4 Performance 2). */
    fun aSideIntent(): Intent? {
        val name = ShellConfig.aSideActivity(appContext) ?: return null
        val clazz = runCatching { Class.forName(name) }.getOrNull() ?: run {
            Log.e(TAG, "Metadata ${ShellConfig.META_A_SIDE_ACTIVITY} refers to a missing class: $name")
            return null
        }
        @Suppress("UNCHECKED_CAST")
        return Intent(appContext, clazz as Class<out Activity>)
    }

    /**
     * §8.3 Calls prohibited on normal execution paths.
     *
     * Block deletion but allow reads: the §12.1 self-test uses
     * `await navigator.serviceWorker.getRegistration()`, which must remain available.
     */
    private val FORBIDDEN_JS = listOf(
        "caches.delete",
        ".unregister(",
        "localStorage.clear",
        "sessionStorage.clear",
        "indexedDB.deleteDatabase",
    )
}
