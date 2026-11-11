package com.ssg.ssg_shell

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
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
 * §6.2 Permission timing and §10.3 battery optimization exemption.
 *
 * Two mandatory requirements:
 * - **Request access only when needed, never during startup.**
 * - Request notification permission **after eventLogin**. Asking before login causes high denial rates,
 *   and most systems restrict subsequent permission prompts.
 *
 * Microphone access is handled separately: §6.2 requires getUserMedia to trigger the native
 * onPermissionRequest callback before requesting system access; see [ImActivity].
 * Photo access is also separate: §7.3 uses the system photo picker without library permission.
 */
internal object PermissionCoordinator {

    private const val TAG = "SsgShell"
    internal const val REQ_NOTIFICATION = 0x55A1

    /** Current foreground Activity. Permission requests need an Activity; B side may have no Flutter Activity. */
    @Volatile
    private var topActivity: Activity? = null

    private var pendingNotification: ((NotificationPermission) -> Unit)? = null

    /**
     * The Activity that showed the system prompt. It is paused (so [topActivity] is null) when the
     * result arrives, but its rationale flag is what distinguishes DENIED from NOT_DETERMINED.
     */
    private var notificationRequester: Activity? = null

    /** Settings guidance is due but no IM screen is in front; show it on the next [ImActivity] resume. */
    private var notificationGuidePending = false
    private var notificationGuide: AlertDialog? = null
    private var notificationGuideOwner: Activity? = null

    /** §10.3 System settings have no result callback; reread state on foreground entry. */
    private val pendingBattery = mutableListOf<(Boolean) -> Unit>()

    fun attach(context: Context) {
        val app = context.applicationContext as? Application ?: return
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                topActivity = activity
                drainBattery(activity)
                drainNotificationGuide(activity)
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
                if (notificationRequester === activity) notificationRequester = null
                if (notificationGuideOwner === activity) {
                    // Avoid a leaked window; the guide is offered again on the next login.
                    notificationGuide?.dismiss()
                    notificationGuide = null
                    notificationGuideOwner = null
                }
            }
        })
    }

    // ------------------------------------------------------------- Notifications

    fun notificationState(
        context: Context,
        activity: Activity? = topActivity,
    ): NotificationPermission {
        val ctx = context.applicationContext
        // Check channel-level and application-level switches; disabled system settings count as denial.
        val enabled = NotificationManagerCompat.from(ctx).areNotificationsEnabled()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            // Below API 33 there is no runtime notification permission, only the application-wide switch.
            return if (enabled) NotificationPermission.GRANTED else NotificationPermission.DENIED
        }
        val granted = ContextCompat.checkSelfPermission(
            ctx,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        return when {
            granted && enabled -> NotificationPermission.GRANTED
            granted -> NotificationPermission.DENIED // Permission is granted, but the application-wide switch is off.
            else -> {
                when {
                    activity == null -> NotificationPermission.NOT_DETERMINED
                    ActivityCompat.shouldShowRequestPermissionRationale(
                        activity,
                        Manifest.permission.POST_NOTIFICATIONS,
                    ) -> NotificationPermission.DENIED
                    // Both never-requested and permanently-denied permissions return false from shouldShowRationale;
                    // use a persisted marker to distinguish them.
                    hasAsked(ctx) -> NotificationPermission.PERMANENTLY_DENIED
                    else -> NotificationPermission.NOT_DETERMINED
                }
            }
        }
    }

    /**
     * §6.2 Call only after eventLogin.
     *
     * Reject startup requests: they have high denial rates and most systems restrict subsequent prompts,
     * potentially losing notification access for this device permanently.
     */
    fun requestNotification(context: Context, onResult: (NotificationPermission) -> Unit) {
        val current = notificationState(context)
        if (current == NotificationPermission.GRANTED) {
            onResult(current)
            return
        }
        if (!ShellCore.hasLoggedIn()) {
            Log.w(
                TAG,
                "Rejecting notification permission request before eventLogin (§6.2: pre-login requests have high denial rates;" +
                    " most systems restrict repeated prompts)",
            )
            onResult(current)
            return
        }
        if (!canPromptForNotifications(context, current)) {
            // Below API 33, with the app-wide switch off, or after a permanent denial the
            // system prompt cannot help; push silently never arrives. Offer Settings instead.
            offerNotificationSettings()
            onResult(current)
            return
        }
        val activity = topActivity ?: run {
            Log.w(TAG, "No foreground Activity; skipping notification permission request")
            onResult(current)
            return
        }
        markAsked(context)
        pendingNotification = onResult
        notificationRequester = activity
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQ_NOTIFICATION,
        )
    }

    /** Forwarded by [ImActivity] and the plugin Activity binding. */
    fun onRequestPermissionsResult(
        context: Context,
        requestCode: Int,
        @Suppress("UNUSED_PARAMETER") permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQ_NOTIFICATION) return false
        val callback = pendingNotification ?: return true
        pendingNotification = null
        val state = notificationState(context, notificationRequester ?: topActivity)
        notificationRequester = null
        // An empty result means the prompt was interrupted, not that the user decided.
        if (grantResults.isNotEmpty() && state != NotificationPermission.GRANTED) {
            offerNotificationSettings()
        }
        callback(state)
        return true
    }

    /** Only a not-yet-granted runtime permission on API 33+ can be fixed by the system prompt. */
    private fun canPromptForNotifications(
        context: Context,
        current: NotificationPermission,
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        if (current == NotificationPermission.PERMANENTLY_DENIED) return false
        return ContextCompat.checkSelfPermission(
            context.applicationContext,
            Manifest.permission.POST_NOTIFICATIONS,
        ) != PackageManager.PERMISSION_GRANTED
    }

    /**
     * §6.2 Settings guidance for disabled notifications. It is shown only over the IM screen,
     * never over the A side, and deferred until [ImActivity] is in front.
     */
    private fun offerNotificationSettings() {
        val activity = topActivity as? ImActivity
        if (activity == null || activity.isFinishing || activity.isDestroyed) {
            notificationGuidePending = true
            return
        }
        showNotificationGuide(activity)
    }

    private fun drainNotificationGuide(activity: Activity) {
        if (!notificationGuidePending || activity !is ImActivity) return
        notificationGuidePending = false
        // Logout, or the user enabled notifications meanwhile: nothing to guide.
        if (!ShellCore.hasLoggedIn() ||
            notificationState(activity, activity) == NotificationPermission.GRANTED
        ) {
            return
        }
        showNotificationGuide(activity)
    }

    private fun showNotificationGuide(activity: Activity) {
        notificationGuidePending = false
        if (notificationGuide?.isShowing == true) return
        notificationGuideOwner = activity
        notificationGuide = AlertDialog.Builder(activity)
            .setTitle(R.string.ssg_shell_notification_off_title)
            .setMessage(R.string.ssg_shell_notification_off_body)
            .setNegativeButton(R.string.ssg_shell_cancel, null)
            .setPositiveButton(R.string.ssg_shell_open_settings) { _, _ ->
                openNotificationSettings(activity)
            }
            .setOnDismissListener {
                notificationGuide = null
                notificationGuideOwner = null
            }
            .show()
    }

    /** Opens this app's notification page, which also grants POST_NOTIFICATIONS on API 33+. */
    fun openNotificationSettings(activity: Activity) {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
        } else {
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", activity.packageName, null),
            )
        }
        runCatching { activity.startActivity(intent) }
            .onFailure {
                Log.w(TAG, "Unable to open notification settings; falling back to app details", it)
                openAppSettings(activity)
            }
    }

    // ------------------------------------------------- Settings guidance / battery optimization

    /** §6.2 Native code provides settings guidance after permanent denial; the Web application cannot open system settings itself. */
    fun openAppSettings(context: Context) {
        val ctx = context.applicationContext
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", ctx.packageName, null),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { ctx.startActivity(intent) }
            .onFailure { Log.e(TAG, "Unable to open device settings", it) }
    }

    fun isBatteryOptimizationIgnored(context: Context): Boolean {
        val ctx = context.applicationContext
        val pm = ctx.getSystemService(PowerManager::class.java) ?: return false
        return runCatching { pm.isIgnoringBatteryOptimizations(ctx.packageName) }
            .getOrDefault(false)
    }

    /**
     * §10.3 Request battery optimization exemption to prevent Doze from freezing the process.
     *
     * §6.2 prohibits prompting on first launch; offer it from settings or after reports of missing messages.
     * This method therefore runs only when explicitly called by Dart, never automatically by the plugin.
     *
     * The system settings page has no result callback; the state can only be re-read after the app returns to the foreground.
     *
     * Showing the system confirmation dialog directly requires the host to declare `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (it is not in the §6.3
     * list, so the plugin does not declare it for the host). Without it, fall back to the system battery optimization list and let the user find the app.
     */
    fun requestBatteryOptimizationExemption(context: Context, onResult: (Boolean) -> Unit) {
        if (isBatteryOptimizationIgnored(context)) {
            onResult(true)
            return
        }
        val ctx = context.applicationContext
        val canAskDirectly = ContextCompat.checkSelfPermission(
            ctx,
            Manifest.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        @Suppress("BatteryLife") // Keep-alive capability required by the spec; purpose in §10.3
        val intent = if (canAskDirectly) {
            Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.fromParts("package", ctx.packageName, null),
            )
        } else {
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val launched = runCatching { ctx.startActivity(intent); true }
            .onFailure { Log.w(TAG, "Unable to open battery optimization exemption settings", it) }
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

    // ------------------------------------------------------------- Persistence

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
