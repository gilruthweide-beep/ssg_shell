package com.ssg.ssg_shell

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

/**
 * Android implementation of the Pigeon contract.
 *
 * This layer only forwards calls; [ShellCore], a process singleton, owns the state. Under §8.4 Performance 2,
 * `ImActivity` can be the first cold-start Activity before Flutter starts, while the §11.1 heartbeat
 * and §11.2 liveness monitor must already be active. Plugin detachment must not stop them.
 */
class SsgShellPlugin : FlutterPlugin, ActivityAware, SsgShellHostApi {

    companion object {
        /**
         * When `ImActivity` is the first Activity on cold start, the plugin starts a headless engine to run Dart
         * (see [ShellCore.ensureDartEngine]) and puts it into `FlutterEngineCache` under this id.
         * The host's FlutterActivity can reuse it by overriding `getCachedEngineId()` to return this id.
         */
        const val ENGINE_ID = "ssg_shell"
    }

    private lateinit var appContext: Context
    private var binding: ActivityPluginBinding? = null

    /** This engine's own Dart callback channel. */
    private var flutterApi: SsgShellFlutterApi? = null

    /** Stateful events missed before Dart came online are replayed only on its first `initialize()`; after that everything is real-time. */
    private var stickyReplayed = false

    /** §6.2 System callback for the notification permission, forwarded to [PermissionCoordinator]. */
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
        // Normally androidx.startup already initialized the shell; this handles hosts that removed its provider.
        ShellStartupInitializer.ensure(appContext)
        SsgShellHostApi.setUp(binding.binaryMessenger, this)
        flutterApi = SsgShellFlutterApi(binding.binaryMessenger).also(ShellCore::addDartApi)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        SsgShellHostApi.setUp(binding.binaryMessenger, null)
        // Once the engine is gone, stop sending events to it, but the shell itself keeps running (§8.4 Performance 2).
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
        // Reaching here means Dart has attached its receiver. The replay must go out before the return value.
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
