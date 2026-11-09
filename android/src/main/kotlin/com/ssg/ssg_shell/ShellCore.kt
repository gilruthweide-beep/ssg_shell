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
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 壳的大脑。进程级单例，不依赖 Flutter 引擎是否活着。
 *
 * 之所以不把这些挂在 `SsgShellPlugin` 上：按 §8.4 体验与性能 2，`ImActivity` 可以是冷启动
 * 的第一个 Activity，那时 Flutter 引擎还没起来；而 §11.2 的存活监测、§11.1 的心跳、
 * §10.4 的网络通知都必须在那一刻就已经在跑。
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

    /** Dart 侧的回调通道。引擎没起来或已销毁时为 null，所有 emit 自动跳过。 */
    @Volatile
    private var dart: SsgShellFlutterApi? = null

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

    /** IM 容器（[ImActivity]）是否挂着 WebView 并可见。 */
    @Volatile
    var imRunning: Boolean = false
        private set

    /** 上一次计算出的「WebView 可见」状态，用于只在翻转时通知 Web。 */
    private var webVisible: Boolean = false

    @Volatile
    private var webReady: Boolean = false
    private var lastWebReadyAtMs: Long? = null

    /** §5.3 冷启动点通知时 Web 还没初始化完，参数要暂存，收到 webReady 再调。 */
    private var pendingOpenChat: OpenChatRequest? = null

    @Volatile
    private var injectionOk: Boolean = false

    /** §6.2 收到 `eventLogin` 之后才允许申请通知权限。 */
    @Volatile
    private var loginSeen: Boolean = false

    private var started = false

    // -------------------------------------------------------------- 装配

    /** 由 [ShellStartupInitializer]（进程启动）或 [SsgShellPlugin] 调，幂等。 */
    fun attach(context: Context) {
        if (started) return
        started = true
        appContext = context.applicationContext
        config = ShellConfig.fromDisk(appContext)
        console.capacity = config.consoleBufferSize

        // §4 / §10.2 进程级前后台。不依赖宿主 Activity，Flutter 页和 ImActivity 互切
        // 不会被误判成回前台。
        main.post {
            ProcessLifecycleOwner.get().lifecycle.addObserver(
                object : DefaultLifecycleObserver {
                    override fun onStart(owner: LifecycleOwner) = setAppForeground(true)
                    override fun onStop(owner: LifecycleOwner) = setAppForeground(false)
                },
            )
        }

        // §11.4 在 Application 的 onTrimMemory 里判断后直接调用，
        // 不要经 Flutter 的 didHaveMemoryPressure 转发。
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

        // §11.7 内核版本引导：低于 92 一次性提示，允许忽略，不要阻断启动。
        kernelInfo().let { info ->
            if (info.verdict == KernelVerdict.BELOW_MINIMUM) {
                Log.w(TAG, "WebView 内核 ${info.versionName} 低于 ${config.minKernelVersion}（§8.1 / §11.7）")
            }
        }
    }

    fun setDartApi(api: SsgShellFlutterApi?) {
        dart = api
    }

    fun requireContext(): Context = appContext

    fun config(): ShellConfig = config

    // ----------------------------------------------------------- HostApi

    fun initialize(dto: ShellConfigDto): ShellInfo {
        val next = ShellConfig.fromDto(appContext, dto)
        config = next
        console.capacity = next.consoleBufferSize
        // §9.6 落盘，下次冷启动 ImActivity 直接按缓存走，不等 Dart。
        ShellConfig.persist(appContext, next)
        return ShellInjection.shellInfo(appContext, next.shellVersion)
    }

    /** §8.4 体验与性能 1：B 面开启时提前创建 WebView 并开始加载；未开启时不预加载。 */
    fun preload() {
        if (!config.bSideEnabled) {
            Log.i(TAG, "B 面未开启，跳过 IM 预加载（§8.4 体验与性能 1）")
            return
        }
        if (config.entryUrl.isBlank()) {
            Log.w(TAG, "entryUrl 为空，预加载跳过")
            return
        }
        main.post { ImWebViewHolder.get(appContext, config) }
    }

    fun openIm() {
        main.post {
            val intent = Intent(appContext, ImActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                // launchMode=singleTask，已在栈里就复用，不会出现第二个实例（§10.5）。
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            runCatching { appContext.startActivity(intent) }
                .onFailure { Log.e(TAG, "打开 ImActivity 失败", it) }
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
     * §5.3 打开会话。
     *
     * 等 `eventWebReady` 再调：冷启动点通知时 Web 还没初始化完，需把参数暂存，收到后再调。
     * 只调一次 —— Web 内部会等会话数据就绪（最长 20 秒）再跳转，不需要原生重试。
     */
    fun openChat(request: OpenChatRequest) {
        if (request.chatId.isBlank()) return
        main.post {
            if (!webReady) {
                pendingOpenChat = request
                emit(
                    ShellEventType.DEEP_LINK_QUEUED,
                    "Web 未就绪，已暂存 chatId=${request.chatId}",
                    mapOf("chatId" to request.chatId),
                )
                return@post
            }
            deliverOpenChat(request)
        }
    }

    private fun deliverOpenChat(request: OpenChatRequest) {
        val payload = JSONObject().apply {
            // §5.3 chatId 传字符串。
            put("chatId", request.chatId)
            // messageId 传数字或可被 Number() 解析的字符串，可省略。
            request.messageId?.takeIf { it.isNotBlank() }?.let { raw ->
                val asNumber = raw.trim().toLongOrNull()
                if (asNumber != null) put("messageId", asNumber) else put("messageId", raw)
            }
        }
        ImWebViewHolder.callWeb("openChat", payload.toString())
        emit(
            ShellEventType.DEEP_LINK_DELIVERED,
            "已交给 Web：chatId=${request.chatId}",
            buildMap {
                put("chatId", request.chatId)
                request.messageId?.let { put("messageId", it) }
            },
        )
    }

    /** §5.4 前台抑制 + §11.3 推送捅醒。 */
    fun handlePushReceived(message: PushMessage): PushDecision {
        val chatId = message.chatId
        val suppress = gate.shouldSuppress(
            chatId = chatId,
            appInForeground = appInForeground,
            enabled = config.suppressForegroundNotifications,
        )

        // §11.3 一条消息的推送到达而 App 正在前台，说明这条消息 Web 没有通过长连接收到，
        // 连接已死。除了按 §5.4 抑制通知，额外调一次 onNetwork 把 Web 捅醒。
        var nudged = false
        if (appInForeground) {
            // 推送都到了，网络一定是通的；监听器还没把 VALIDATED 翻过来时按 other 算。
            val observed = network?.currentType ?: NetworkType.NONE
            val type = if (observed == NetworkType.NONE) NetworkType.OTHER else observed
            main.post { deliverNetwork(type) }
            nudged = true
        }

        val reason = buildString {
            append(if (appInForeground) "前台" else "后台")
            append("；tracked=").append(gate.trackedChatId ?: "-")
            append("；incoming=").append(chatId ?: "-")
            if (suppress) append("；命中前台抑制")
            if (nudged) append("；已调 onNetwork 捅醒")
        }
        Log.i(TAG, "handlePushReceived: $reason")

        return PushDecision(
            suppressNotification = suppress,
            nudgedWeb = nudged,
            appInForeground = appInForeground,
            reason = reason,
        )
    }

    /** §5.3 通知点击。 */
    fun handlePushOpened(message: PushMessage) {
        val chatId = message.chatId?.takeIf { it.isNotBlank() }
        if (config.bSideEnabled) openIm()
        if (chatId == null) {
            Log.w(TAG, "通知点击里没有 chat_id，只打开 App")
            return
        }
        openChat(OpenChatRequest(chatId = chatId, messageId = message.messageId))
    }

    fun nudgeNetwork(type: NetworkType) {
        main.post { deliverNetwork(type) }
    }

    fun reloadWeb() {
        main.post {
            Log.i(TAG, "手动 reload（§11.2）")
            ImWebViewHolder.reload()
        }
    }

    fun recreateWebView() {
        main.post {
            // §11.2.3 **必须先结束渲染进程再重建。** 同一个 App 的所有 WebView 共用一个
            // 渲染进程，死循环卡住的是这个进程；只换 WebView 实例的话新实例同样卡住。
            if (ImWebViewHolder.terminateRenderProcess()) {
                // terminate 会触发 §7.1 的 onRenderProcessGone，重建在那条路径上统一完成，
                // 避免同时存在两个实例（§10.5）。
                Log.i(TAG, "已结束渲染进程，等 onRenderProcessGone 重建")
                return@post
            }
            Log.w(TAG, "渲染进程未能结束，直接换 WebView 实例（旧内核兜底，§11.2.3）")
            doRecreate()
        }
    }

    private fun doRecreate() {
        webReady = false
        gate.onPageLoadStarted()
        ImWebViewHolder.recreate(appContext, config)
        watchdog.onWebViewRecreated()
        emit(ShellEventType.WEB_VIEW_RECREATED, "WebView 实例已重建", emptyMap())
    }

    fun setBadgeCount(count: Int) {
        gate.setBadge(count)
        BadgeApplier.apply(appContext, count)
    }

    fun verifyInjection(onResult: (Boolean) -> Unit) {
        // §1.3 这是 Web 侧的判定结果。只要它是 true，无论 __SSG_SHELL__ 打印出什么都算失败。
        val js = "document.documentElement.classList.contains('is-web-browser')"
        main.post {
            ImWebViewHolder.evaluate(js) { raw ->
                val isBrowser = raw?.trim()?.trim('"')
                val ok = isBrowser == "false"
                injectionOk = ok
                emit(
                    ShellEventType.INJECTION_CHECKED,
                    if (ok) "注入生效" else "注入未生效（is-web-browser=$isBrowser），见 §1.2",
                    mapOf("isWebBrowser" to (isBrowser ?: "null")),
                )
                onResult(ok)
            }
        }
    }

    fun evaluateJavaScript(script: String, onResult: (Result<String>) -> Unit) {
        // §8.3 存储不要清。清存储的后果：用户被登出、本地消息缓存全失、媒体重新下载一遍、
        // 诊断上下文丢失，并且 eventRegister 的「每设备一次」标记被抹掉，渠道注册数虚高。
        FORBIDDEN_JS.firstOrNull { script.contains(it, ignoreCase = true) }?.let { hit ->
            onResult(
                Result.failure(
                    IllegalArgumentException(
                        "脚本包含禁止的存储清理调用「$hit」，见 §8.3。只能由用户显式「清除数据」触发。",
                    ),
                ),
            )
            return
        }
        main.post {
            ImWebViewHolder.evaluate(script) { raw -> onResult(Result.success(raw.orEmpty())) }
        }
    }

    // ------------------------------------------------------------ 诊断

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
        channelCode = config.channelCode,
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

    /** §11.6 导出：当前 URL、UA、内核版本、`__SSG_SHELL__`、最近一次 reload 时间、最近 N 条 console。 */
    fun exportDiagnostics(): String {
        val d = diagnostics()
        val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.ROOT)
        fun time(ms: Long?) = ms?.let { fmt.format(Date(it)) } ?: "-"
        return buildString {
            appendLine("==== SSG Shell 诊断 ====")
            appendLine("导出时间        ${fmt.format(Date())}")
            appendLine("平台            android")
            appendLine("包名            ${d.shellInfo.bundleId}")
            appendLine("壳版本          ${d.shellInfo.shellVersion}")
            appendLine("机型            ${d.shellInfo.deviceModel}")
            appendLine("系统版本        ${d.shellInfo.osVersion}")
            appendLine("内核版本        ${d.kernel.versionName} (${d.kernel.verdict}) ${d.kernel.packageName}")
            appendLine("入口地址        ${d.entryUrl}")
            appendLine("当前地址        ${d.currentUrl}")
            appendLine("UA              ${d.userAgent}")
            appendLine("channelCode     ${d.channelCode.ifBlank { "(空，渠道归因丢失)" }}")
            appendLine("注入自检        ${if (d.injectionOk) "通过 shellSrc:inject" else "未通过，见 §1.2"}")
            appendLine("IM 挂载         ${d.imRunning}")
            appendLine("App 前台        ${d.appInForeground}")
            appendLine("最近 webReady   ${time(d.lastWebReadyAtMs)}")
            appendLine("最近 webAlive   ${time(d.lastWebAliveAtMs)}")
            appendLine("最近 reload     ${time(d.lastReloadAtMs)}  次数 ${d.reloadCount}")
            appendLine("WebView 重建    ${d.recreateCount} 次")
            appendLine("当前会话        ${d.trackedChatId ?: "-"}")
            appendLine("角标            ${d.badgeCount}")
            appendLine()
            appendLine("---- 最近 ${d.consoleTail.size} 条 console ----")
            appendLine(console.dump())
        }
    }

    // ------------------------------------------------- WebView 回调入口

    /** §3.1 从 [JsBridge] 过来，可能在 JS 线程上，必须切主线程。 */
    fun onWebEvent(event: WebEvent) {
        main.post { handleWebEvent(event) }
    }

    private fun handleWebEvent(event: WebEvent) {
        when (event.name) {
            WebEventName.WEB_READY -> {
                webReady = true
                lastWebReadyAtMs = event.receivedAtMs
                // §9.6 收到 eventWebReady 后立即撤 splash，不要用固定时长定时器。
                ImWebViewHolder.host?.dismissSplash(ShellEventType.SPLASH_DISMISSED)
                // §5.3 冷启动点通知时暂存的参数，就绪后补发，只调一次。
                pendingOpenChat?.let { queued ->
                    pendingOpenChat = null
                    deliverOpenChat(queued)
                }
                // §1.3 首屏可见即可自检，不用等人去连调试器。
                verifyInjection {}
            }

            WebEventName.WEB_ALIVE -> watchdog.onWebAlive()

            WebEventName.CHAT_OPEN -> gate.onChatOpen(event.chatId)

            WebEventName.CHAT_CLOSE -> gate.onChatClose(event.chatId)

            WebEventName.UNREAD_COUNT -> {
                val count = (event.unreadCount ?: 0L).toInt()
                gate.onUnreadCount(count)
                // §5.4 角标数 = Web 给的未读总数，count 为 0 时清零。
                if (config.manageBadge) BadgeApplier.apply(appContext, count)
            }

            // §6.2 通知权限在收到 eventLogin 之后才允许申请，这里只放开闸门，
            // 真正弹窗由 Dart 侧决定时机（宿主可能要先做自己的引导页）。
            WebEventName.LOGIN -> loginSeen = true

            WebEventName.LOGOUT -> {
                loginSeen = false
                // §5.4 退出登录时 Web 会发 unreadCount=0，这里不额外清，交给那条事件。
            }

            else -> Unit
        }

        dart?.onWebEvent(event) { /* Dart 侧没挂监听不是错误 */ }
    }

    fun hasLoggedIn(): Boolean = loginSeen

    fun onPageStarted(url: String?) {
        // §5.4 页面重新加载时不会发 chatClose，原生在页面开始加载时要清空记住的 chatId。
        gate.onPageLoadStarted()
        webReady = false
        watchdog.onPageStarted()
        watchdog.onPageLoadStartedExternally()
        ImWebViewHolder.host?.hideErrorPage()
        Log.d(TAG, "onPageStarted $url")
    }

    fun onPageFinished(url: String?) {
        Log.d(TAG, "onPageFinished $url")
    }

    fun onMainFrameLoadFailed(url: String, description: String) {
        Log.w(TAG, "首屏加载失败 $url: $description")
        main.post {
            ImWebViewHolder.host?.showErrorPage(null)
            emit(ShellEventType.LOAD_FAILED, description, mapOf("url" to url))
        }
    }

    fun onSslError(primaryError: Int) {
        main.post {
            ImWebViewHolder.host?.showErrorPage(
                appContext.getString(R.string.ssg_shell_ssl_body),
            )
            emit(
                ShellEventType.LOAD_FAILED,
                "SSL 校验失败（primaryError=$primaryError）",
                mapOf("sslError" to primaryError.toString()),
            )
        }
    }

    fun onRenderProcessGone(crashed: Boolean) {
        main.post {
            emit(
                ShellEventType.RENDER_PROCESS_GONE,
                if (crashed) "渲染进程崩溃" else "渲染进程被回收或主动结束",
                mapOf("didCrash" to crashed.toString()),
            )
            // §7.1 旧实例已不可用，不能对它 reload：销毁旧 WebView、新建一个加载入口地址。
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
        // §11.6 把 Web 的 console 落到原生日志。
        val tag = "SsgShellWeb"
        when (level) {
            ConsoleLevel.ERROR -> Log.e(tag, message)
            ConsoleLevel.WARNING -> Log.w(tag, message)
            ConsoleLevel.DEBUG -> Log.d(tag, message)
            else -> Log.i(tag, message)
        }
        main.post {
            dart?.onShellEvent(
                ShellEvent(
                    type = ShellEventType.CONSOLE_MESSAGE,
                    atMs = record.atMs,
                    extra = emptyMap(),
                    message = message,
                    console = record,
                ),
            ) {}
        }
    }

    /**
     * §11.4 内存告警。
     *
     * 只在 `TRIM_MEMORY_RUNNING_LOW` 或 `TRIM_MEMORY_RUNNING_CRITICAL` 时调。
     * **不要写成 `level >= TRIM_MEMORY_RUNNING_LOW`**：切后台时系统必发
     * `TRIM_MEMORY_UI_HIDDEN`（值 20，比 `RUNNING_LOW` 的 10 大），会被误当成内存告警。
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

    // ------------------------------------------------------- 生命周期

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
     * §10.2 回前台信号。
     *
     * 判据是「WebView 真的可见」而不是「App 在前台」：IM 页和 Flutter 的 A 面互切时
     * App 一直在前台，但 WebView 已经 `onPause()`，Web 的 `document.hidden` 翻成 true、
     * 停发 `eventWebAlive`。这时如果 §11.2 的计时还在跑，60 秒后会误判卡死。
     */
    private fun updateWebVisibility() {
        val visible = appInForeground && imRunning
        if (visible == webVisible) return
        webVisible = visible
        if (visible) {
            // §10.2.2 先 onResume()：让 document.hidden 翻转，visibilitychange 成为
            // 独立于注入的第二条通道。
            ImWebViewHolder.onResumeWeb()
            // §10.2.1 每次回前台都调 onForeground()。锁屏解锁、从后台任务切回、
            // 从通知点进来都算。注入生效后，后台停留超过 1.5 秒回前台即立刻重连。
            ImWebViewHolder.callWeb("onForeground")
            watchdog.onForeground()
            emit(ShellEventType.FOREGROUND, null, emptyMap())
        } else {
            ImWebViewHolder.callWeb("onBackground")
            // §10.3 只调 onPause()（暂停渲染和可见性），不调 pauseTimers()。
            ImWebViewHolder.onPauseWeb()
            watchdog.onBackground()
            emit(ShellEventType.BACKGROUND, null, emptyMap())
        }
    }

    private fun deliverNetwork(type: NetworkType) {
        // §4 断网时不用调，传 none 会被忽略。
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

    // ------------------------------------------------------------ 杂项

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
            dart?.onShellEvent(event) {}
        } else {
            main.post { dart?.onShellEvent(event) {} }
        }
    }

    fun notifySplashDismissed(reason: ShellEventType) {
        emit(reason, null, emptyMap())
    }

    /** 给 [ImActivity] 用：取 A 面 Activity，B 面未开启时转过去并结束自己（§8.4 体验与性能 2）。 */
    fun aSideIntent(): Intent? {
        val name = ShellConfig.aSideActivity(appContext) ?: return null
        val clazz = runCatching { Class.forName(name) }.getOrNull() ?: run {
            Log.e(TAG, "meta-data ${ShellConfig.META_A_SIDE_ACTIVITY} 指向的类不存在：$name")
            return null
        }
        @Suppress("UNCHECKED_CAST")
        return Intent(appContext, clazz as Class<out Activity>)
    }

    /**
     * §8.3 不允许出现在任何常规路径上的调用。
     *
     * 只拦「清」，不拦「读」：§12.1 的自测要跑
     * `await navigator.serviceWorker.getRegistration()`，那是读，必须放行。
     */
    private val FORBIDDEN_JS = listOf(
        "caches.delete",
        ".unregister(",
        "localStorage.clear",
        "sessionStorage.clear",
        "indexedDB.deleteDatabase",
    )
}
