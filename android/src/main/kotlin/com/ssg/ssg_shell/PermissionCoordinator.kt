package com.ssg.ssg_shell

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * §6.2 申请时机 + §10.3 电池优化白名单。
 *
 * 规范的两条硬要求：
 * - **用到的那一刻才申请，启动阶段一律不申请。**
 * - 通知权限在**收到 `eventLogin` 之后**才申请。未登录状态弹授权拒绝率极高，
 *   多数系统不允许二次申请。
 *
 * 麦克风不走这里：§6.2 要求由 `getUserMedia` 触发，原生在 §7.1 的
 * `onPermissionRequest` 授权回调里再向系统申请，见 [ImActivity]。
 * 相册也不走这里：§7.3 用系统照片选择器，不申请相册权限。
 */
internal object PermissionCoordinator {

    private const val TAG = "SsgShell"
    internal const val REQ_NOTIFICATION = 0x55A1

    /** 当前最前面的 Activity。申请权限必须有 Activity，而 B 面下可能根本没有 Flutter Activity。 */
    @Volatile
    private var topActivity: Activity? = null

    private var pendingNotification: ((NotificationPermission) -> Unit)? = null

    /** §10.3 系统设置页没有结果回调，只能回前台后重新读一次状态。 */
    private val pendingBattery = mutableListOf<(Boolean) -> Unit>()

    fun attach(context: Context) {
        val app = context.applicationContext as? Application ?: return
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                topActivity = activity
                drainBattery(activity)
            }

            override fun onActivityPaused(activity: Activity) {
                if (topActivity === activity) topActivity = null
            }

            override fun onActivityCreated(activity: Activity, bundle: Bundle?) = Unit
            override fun onActivityStarted(activity: Activity) = Unit
            override fun onActivityStopped(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, bundle: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) {
                if (topActivity === activity) topActivity = null
            }
        })
    }

    // ------------------------------------------------------------- 通知

    fun notificationState(context: Context): NotificationPermission {
        val ctx = context.applicationContext
        // 渠道级和应用级总开关：用户在系统设置里关掉了也算拒绝。
        val enabled = NotificationManagerCompat.from(ctx).areNotificationsEnabled()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            // API 33 以下没有运行时权限，只有通知总开关。
            return if (enabled) NotificationPermission.GRANTED else NotificationPermission.DENIED
        }
        val granted = ContextCompat.checkSelfPermission(
            ctx,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        return when {
            granted && enabled -> NotificationPermission.GRANTED
            granted -> NotificationPermission.DENIED // 权限有，但总开关被关
            else -> {
                val activity = topActivity
                when {
                    activity == null -> NotificationPermission.NOT_DETERMINED
                    ActivityCompat.shouldShowRequestPermissionRationale(
                        activity,
                        Manifest.permission.POST_NOTIFICATIONS,
                    ) -> NotificationPermission.DENIED
                    // 从没问过，和「问过并永久拒绝」在 shouldShowRationale 上都是 false，
                    // 用一个落盘标记区分。
                    hasAsked(ctx) -> NotificationPermission.PERMANENTLY_DENIED
                    else -> NotificationPermission.NOT_DETERMINED
                }
            }
        }
    }

    /**
     * §6.2 只在收到 `eventLogin` 之后调。
     *
     * 启动期调用会被直接拒掉：那一次弹窗的拒绝率极高，而多数系统不允许二次申请，
     * 等于永久放弃这台设备的推送。
     */
    fun requestNotification(context: Context, onResult: (NotificationPermission) -> Unit) {
        val current = notificationState(context)
        if (current == NotificationPermission.GRANTED ||
            current == NotificationPermission.PERMANENTLY_DENIED
        ) {
            onResult(current)
            return
        }
        if (!ShellCore.hasLoggedIn()) {
            Log.w(
                TAG,
                "还没收到 eventLogin，拒绝申请通知权限（§6.2：未登录状态弹授权拒绝率极高，" +
                    "多数系统不允许二次申请）",
            )
            onResult(current)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            // 没有运行时权限可申请，只能引导去系统设置开总开关。
            onResult(current)
            return
        }
        val activity = topActivity ?: run {
            Log.w(TAG, "没有前台 Activity，通知权限申请跳过")
            onResult(current)
            return
        }
        markAsked(context)
        pendingNotification = onResult
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQ_NOTIFICATION,
        )
    }

    /** 由 [ImActivity] 和插件的 Activity 绑定共同转发进来。 */
    fun onRequestPermissionsResult(
        context: Context,
        requestCode: Int,
        @Suppress("UNUSED_PARAMETER") permissions: Array<out String>,
        @Suppress("UNUSED_PARAMETER") grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQ_NOTIFICATION) return false
        val callback = pendingNotification
        pendingNotification = null
        callback?.invoke(notificationState(context))
        return true
    }

    // ------------------------------------------------- 二次引导 / 电池优化

    /** §6.2 权限被永久拒绝后的二次引导由原生负责。Web 只能弹一句提示，拿不到系统设置页。 */
    fun openAppSettings(context: Context) {
        val ctx = context.applicationContext
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", ctx.packageName, null),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { ctx.startActivity(intent) }
            .onFailure { Log.e(TAG, "打开系统设置失败", it) }
    }

    fun isBatteryOptimizationIgnored(context: Context): Boolean {
        val ctx = context.applicationContext
        val pm = ctx.getSystemService(PowerManager::class.java) ?: return false
        return runCatching { pm.isIgnoringBatteryOptimizations(ctx.packageName) }
            .getOrDefault(false)
    }

    /**
     * §10.3 申请电池优化白名单，避免进程被 Doze 冻死。
     *
     * §6.2 明确「不在首启弹」—— 放设置页引导，或用户反馈收不到消息时再引导，
     * 所以这个方法只在 Dart 显式调用时才走，插件自己不会调。
     *
     * 系统设置页没有结果回调，只能等 App 回到前台后重新读一次状态。
     */
    fun requestBatteryOptimizationExemption(context: Context, onResult: (Boolean) -> Unit) {
        if (isBatteryOptimizationIgnored(context)) {
            onResult(true)
            return
        }
        val ctx = context.applicationContext
        @Suppress("BatteryLife") // 规范要求的保活能力，用途在 §10.3
        val intent = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.fromParts("package", ctx.packageName, null),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val launched = runCatching { ctx.startActivity(intent); true }
            .onFailure { Log.w(TAG, "拉起电池优化白名单页失败", it) }
            .getOrDefault(false)
        if (!launched) {
            onResult(false)
            return
        }
        synchronized(pendingBattery) { pendingBattery += onResult }
    }

    private fun drainBattery(activity: Activity) {
        val waiting = synchronized(pendingBattery) {
            if (pendingBattery.isEmpty()) return
            pendingBattery.toList().also { pendingBattery.clear() }
        }
        val granted = isBatteryOptimizationIgnored(activity)
        waiting.forEach { it(granted) }
    }

    // ------------------------------------------------------------- 落盘

    private const val PREFS = "ssg_shell"
    private const val KEY_ASKED_NOTIFICATION = "askedNotification"

    private fun hasAsked(context: Context): Boolean =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_ASKED_NOTIFICATION, false)

    private fun markAsked(context: Context) {
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_ASKED_NOTIFICATION, true).apply()
    }
}
