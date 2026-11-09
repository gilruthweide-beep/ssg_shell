package com.ssg.ssg_shell

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.core.net.toUri

/**
 * §5.4 角标。
 *
 * Android 没有统一的角标 API，各家 launcher 自己一套。这里做尽力而为的实现：
 *
 * - 三星 / 索尼 / LG / HTC / 一加等：`android.intent.action.BADGE_COUNT_UPDATE` 广播。
 * - 华为 / 荣耀：`content://com.huawei.android.launcher.settings/badge/` provider。
 * - **小米 / OPPO / vivo 拿不到**：这几家只认挂在通知上的角标数，必须由推送侧下发
 *   （OneSignal 的通知里带 badge），原生改不了。
 *
 * 所以 §12.3 的角标验收在小米 / OPPO / vivo 上要靠服务端在推送里带未读数；
 * 本类负责的是「App 自己能改的那部分」，以及 `count == 0` 时的清零。
 * iOS 侧是精确的（`setApplicationIconBadgeNumber`）。
 */
internal object BadgeApplier {

    private const val TAG = "SsgShell"

    fun apply(context: Context, count: Int) {
        val ctx = context.applicationContext
        val safe = count.coerceAtLeast(0)
        val launcher = launcherComponent(ctx) ?: run {
            Log.w(TAG, "找不到 launcher Activity，角标设置跳过")
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
                    // 部分 ROM 从 Android 8 起要求显式包名才肯收。
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
        }.onFailure { Log.w(TAG, "角标广播失败", it) }
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
        }.onFailure { /* 非华为设备上必然失败，不记日志免得刷屏 */ }
    }
}
