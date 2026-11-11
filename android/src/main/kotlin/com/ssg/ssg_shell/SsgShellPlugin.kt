package com.ssg.ssg_shell

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

/**
 * Pigeon 契约的 Android 实现入口。
 *
 * 这里只做转发：真正的状态全在 [ShellCore]（进程级单例）。原因见 §8.4 体验与性能 2 ——
 * `ImActivity` 可以是冷启动的第一个 Activity，那时 Flutter 引擎还没起来，而 §11.1 的心跳、
 * §11.2 的存活监测必须已经在跑。插件被 detach（引擎销毁）也不能停掉这些。
 */
class SsgShellPlugin : FlutterPlugin, ActivityAware, SsgShellHostApi {

    companion object {
        /**
         * `ImActivity` 当冷启动第一个 Activity 时，插件会起一个无界面引擎跑 Dart
         * （见 [ShellCore.ensureDartEngine]），并以这个 id 放进 `FlutterEngineCache`。
         * 宿主的 FlutterActivity 覆盖 `getCachedEngineId()` 返回它即可复用。
         */
        const val ENGINE_ID = "ssg_shell"
    }

    private lateinit var appContext: Context
    private var binding: ActivityPluginBinding? = null

    /** 这个引擎自己的 Dart 回调通道。 */
    private var flutterApi: SsgShellFlutterApi? = null

    /** Dart 上线前错过的状态类事件只在它第一次 `initialize()` 时补发，之后都是实时的。 */
    private var stickyReplayed = false

    /** §6.2 通知权限的系统回调，转给 [PermissionCoordinator]。 */
    private val permissionListener =
        io.flutter.plugin.common.PluginRegistry.RequestPermissionsResultListener {
                requestCode, permissions, grantResults ->
            PermissionCoordinator.onRequestPermissionsResult(
                appContext,
                requestCode,
                permissions,
                grantResults,
            )
        }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        // 正常情况下 androidx.startup 已经装配过了，这里只兜宿主把 provider 去掉的情况。
        ShellStartupInitializer.ensure(appContext)
        SsgShellHostApi.setUp(binding.binaryMessenger, this)
        flutterApi = SsgShellFlutterApi(binding.binaryMessenger).also(ShellCore::addDartApi)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        SsgShellHostApi.setUp(binding.binaryMessenger, null)
        // 引擎没了就不要再往它那边发事件，但壳本身继续跑（§8.4 体验与性能 2）。
        flutterApi?.let(ShellCore::removeDartApi)
        flutterApi = null
        stickyReplayed = false
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addRequestPermissionsResultListener(permissionListener)
    }

    override fun onDetachedFromActivity() {
        binding?.removeRequestPermissionsResultListener(permissionListener)
        binding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    // --------------------------------------------------------- SsgShellHostApi

    override fun initialize(config: ShellConfigDto): ShellInfo {
        val info = ShellCore.initialize(config)
        // 调到这里说明 Dart 已经挂好了接收端。补发要赶在返回值之前发出去。
        if (!stickyReplayed) {
            stickyReplayed = true
            flutterApi?.let(ShellCore::replaySticky)
        }
        return info
    }

    override fun preload() = ShellCore.preload()

    override fun openIm() = ShellCore.openIm()

    override fun closeIm() = ShellCore.closeIm()

    override fun isImRunning(): Boolean = ShellCore.imRunning

    override fun setBSideEnabled(enabled: Boolean) = ShellCore.setBSideEnabled(enabled)

    override fun isBSideEnabled(): Boolean = ShellCore.isBSideEnabled()

    override fun openChat(request: OpenChatRequest) = ShellCore.openChat(request)

    override fun handlePushReceived(message: PushMessage): PushDecision =
        ShellCore.handlePushReceived(message)

    override fun handlePushOpened(message: PushMessage) = ShellCore.handlePushOpened(message)

    override fun nudgeNetwork(type: NetworkType) = ShellCore.nudgeNetwork(type)

    override fun reloadWeb() = ShellCore.reloadWeb()

    override fun recreateWebView() = ShellCore.recreateWebView()

    override fun setBadgeCount(count: Long) = ShellCore.setBadgeCount(count.toInt())

    override fun getDiagnostics(): ShellDiagnostics = ShellCore.diagnostics()

    override fun exportDiagnostics(): String = ShellCore.exportDiagnostics()

    override fun getKernelInfo(): KernelInfo = ShellCore.kernelInfo()

    override fun getNotificationPermission(): NotificationPermission =
        PermissionCoordinator.notificationState(appContext)

    override fun requestNotificationPermission(
        callback: (Result<NotificationPermission>) -> Unit,
    ) {
        PermissionCoordinator.requestNotification(appContext) { callback(Result.success(it)) }
    }

    override fun openSystemSettings() = PermissionCoordinator.openAppSettings(appContext)

    override fun requestBatteryOptimizationExemption(callback: (Result<Boolean>) -> Unit) {
        PermissionCoordinator.requestBatteryOptimizationExemption(appContext) {
            callback(Result.success(it))
        }
    }

    override fun isBatteryOptimizationIgnored(): Boolean =
        PermissionCoordinator.isBatteryOptimizationIgnored(appContext)

    override fun verifyInjection(callback: (Result<Boolean>) -> Unit) {
        ShellCore.verifyInjection { callback(Result.success(it)) }
    }

    override fun evaluateJavaScript(script: String, callback: (Result<String>) -> Unit) {
        ShellCore.evaluateJavaScript(script) { callback(it) }
    }
}
