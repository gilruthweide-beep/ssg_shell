package com.ssg.ssg_shell

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.core.net.toUri

/**
 * §5.4 Badge updates.
 *
 * Android launchers expose different badge APIs, so this implementation uses best-effort support:
 *
 * - Samsung / Sony / LG / HTC / OnePlus and others: `android.intent.action.BADGE_COUNT_UPDATE` broadcasts.
 * - Huawei / Honor: the `content://com.huawei.android.launcher.settings/badge/` provider.
 * - **Xiaomi / OPPO / vivo require push-supplied badge counts** attached to notifications;
 *   native badge updates cannot replace the badge value in the OneSignal notification.
 *
 * Therefore §12.3 badge validation on those launchers requires the server to include the unread count in each push.
 * This class manages locally supported badge updates and clearing when `count == 0`.
 * iOS supports exact counts through `setApplicationIconBadgeNumber`.
 */
internal object BadgeApplier {

    private const val TAG = "SsgShell"

    fun apply(context: Context, count: Int) {
        val ctx = context.applicationContext
        val safe = count.coerceAtLeast(0)
        val launcher = launcherComponent(ctx) ?: run {
            Log.w(TAG, "No launcher Activity found; skipping badge update")
            return
        }
        broadcastBadge(ctx, launcher, safe)
        huaweiBadge(ctx, launcher, safe)
    }

    private fun launcherComponent(context: Context): ComponentName? {
        val intent = Intent(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .setPackage(context.packageName)
        return runCatching {
            context.packageManager.queryIntentActivities(intent, 0)
                .firstOrNull()
                ?.activityInfo
                ?.let { ComponentName(it.packageName, it.name) }
        }.getOrNull()
    }

    private fun broadcastBadge(context: Context, launcher: ComponentName, count: Int) {
        runCatching {
            context.sendBroadcast(
                Intent("android.intent.action.BADGE_COUNT_UPDATE").apply {
                    putExtra("badge_count", count)
                    putExtra("badge_count_package_name", launcher.packageName)
                    putExtra("badge_count_class_name", launcher.className)
                    // Some Android 8+ vendor ROMs require an explicit package name on the broadcast.
                    `package` = "com.sec.android.app.launcher"
                },
            )
            context.sendBroadcast(
                Intent("android.intent.action.BADGE_COUNT_UPDATE").apply {
                    putExtra("badge_count", count)
                    putExtra("badge_count_package_name", launcher.packageName)
                    putExtra("badge_count_class_name", launcher.className)
                },
            )
        }.onFailure { Log.w(TAG, "Badge broadcast failed", it) }
    }

    private fun huaweiBadge(context: Context, launcher: ComponentName, count: Int) {
        runCatching {
            val extras = Bundle().apply {
                putString("package", launcher.packageName)
                putString("class", launcher.className)
                putInt("badgenumber", count)
            }
            context.contentResolver.call(
                "content://com.huawei.android.launcher.settings/badge/".toUri(),
                "change_badge",
                null,
                extras,
            )
        }.onFailure { /* Expected to fail on non-Huawei devices; avoid noisy logs. */ }
    }
}
