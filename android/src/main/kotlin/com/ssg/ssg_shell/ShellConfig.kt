package com.ssg.ssg_shell

import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri

/**
 * 壳的运行参数。
 *
 * 有两个来源，按优先级合并：
 *  1. Dart 调 [SsgShellHostApi.initialize] 传下来的 [ShellConfigDto]；
 *  2. 宿主 Manifest 的 `<meta-data>`。
 *
 * 之所以两套都要，是因为 §8.4 体验与性能 2 要求 `ImActivity` 可以直接当冷启动的第一个
 * Activity。那条路径上 Flutter 引擎还没起来，拿不到 Dart 的配置，只能读 Manifest
 * 加上一份落盘的缓存（§9.6「把上次的结果缓存在本地，冷启动直接按缓存走」）。
 */
internal data class ShellConfig(
    /** §2.1 完整落地 URL，原样加载；渠道码可选，由 Web 读取。 */
    val entryUrl: String,
    /** 旧版兼容字段，已忽略，不参与 URL 加载或渠道归因。 */
    val channelCode: String = "",
    /** §1.1 / §2.2 壳版本。 */
    val shellVersion: String,
    /** §9.6 B 面开关。 */
    val bSideEnabled: Boolean,
    val splashTimeoutMs: Long = 30_000,
    val heartbeatIntervalMs: Long = 20_000,
    val aliveTimeoutMs: Long = 60_000,
    val reloadConfirmTimeoutMs: Long = 10_000,
    val recoveryBackoffFirstMs: Long = 180_000,
    val recoveryBackoffLaterMs: Long = 600_000,
    val networkDebounceMs: Long = 1_500,
    val suppressForegroundNotifications: Boolean = true,
    val manageBadge: Boolean = true,
    val minKernelVersion: Int = 92,
    val recommendedKernelVersion: Int = 110,
    val consoleBufferSize: Int = 300,
    val backgroundColorArgb: Int = 0xFFFFFFFF.toInt(),
    val forwardConsole: Boolean = true,
) {
    /** §2.1 原样返回落地 URL，不解析或重拼 query。 */
    fun resolvedUrl(): String = entryUrl

    /** §10.5 判定「是不是 IM 域名」用的 host，用于 §7.1 的外链放行。 */
    fun entryHost(): String? = runCatching { Uri.parse(entryUrl).host }.getOrNull()

    internal companion object {
        private const val META_ENTRY_URL = "com.ssg.shell.ENTRY_URL"
        private const val META_SHELL_VERSION = "com.ssg.shell.SHELL_VERSION"
        internal const val META_A_SIDE_ACTIVITY = "com.ssg.shell.A_SIDE_ACTIVITY"
        internal const val META_AUTO_PRELOAD = "com.ssg.shell.AUTO_PRELOAD"

        private const val PREFS = "ssg_shell"
        private const val KEY_ENTRY_URL = "entryUrl"
        private const val KEY_SHELL_VERSION = "shellVersion"
        private const val KEY_B_SIDE = "bSideEnabled"
        private const val KEY_KERNEL_WARNED = "kernelWarned"

        /** 读 Manifest `<meta-data>` 加上落盘缓存，Dart 还没上线时就用这份。 */
        fun fromDisk(context: Context): ShellConfig {
            val meta = metaData(context)
            val prefs = context.applicationContext
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val metaEntry = meta?.getString(META_ENTRY_URL).orEmpty()
            val metaVersion = meta?.getString(META_SHELL_VERSION).orEmpty()
            return ShellConfig(
                // 落盘的完整入口 URL 优先，包含宿主配置的可选渠道码。
                entryUrl = prefs.getString(KEY_ENTRY_URL, null) ?: metaEntry,
                shellVersion = prefs.getString(KEY_SHELL_VERSION, null)
                    ?: metaVersion.ifBlank { appVersionName(context) },
                // §9.6 没有缓存时默认关：没确认过 B 面就不要抢在 A 面前面。
                bSideEnabled = prefs.getBoolean(KEY_B_SIDE, false),
            )
        }

        fun fromDto(context: Context, dto: ShellConfigDto): ShellConfig = ShellConfig(
            entryUrl = dto.entryUrl,
            shellVersion = dto.shellVersion.ifBlank { appVersionName(context) },
            bSideEnabled = dto.bSideEnabled,
            splashTimeoutMs = dto.splashTimeoutMs,
            heartbeatIntervalMs = dto.heartbeatIntervalMs,
            aliveTimeoutMs = dto.aliveTimeoutMs,
            reloadConfirmTimeoutMs = dto.reloadConfirmTimeoutMs,
            recoveryBackoffFirstMs = dto.recoveryBackoffFirstMs,
            recoveryBackoffLaterMs = dto.recoveryBackoffLaterMs,
            networkDebounceMs = dto.networkDebounceMs,
            suppressForegroundNotifications = dto.suppressForegroundNotifications,
            manageBadge = dto.manageBadge,
            minKernelVersion = dto.minKernelVersion.toInt(),
            recommendedKernelVersion = dto.recommendedKernelVersion.toInt(),
            consoleBufferSize = dto.consoleBufferSize.toInt(),
            backgroundColorArgb = dto.backgroundColorArgb.toInt(),
            forwardConsole = dto.forwardConsole,
        )

        fun persist(context: Context, config: ShellConfig) {
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_ENTRY_URL, config.entryUrl)
                .putString(KEY_SHELL_VERSION, config.shellVersion)
                .putBoolean(KEY_B_SIDE, config.bSideEnabled)
                .apply()
        }

        fun persistBSide(context: Context, enabled: Boolean) {
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_B_SIDE, enabled).apply()
        }

        /** §11.7 内核过低的提示只给一次，用户忽略了就不再烦他。 */
        fun kernelWarned(context: Context): Boolean =
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean(KEY_KERNEL_WARNED, false)

        fun markKernelWarned(context: Context) {
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_KERNEL_WARNED, true).apply()
        }

        fun aSideActivity(context: Context): String? =
            metaData(context)?.getString(META_A_SIDE_ACTIVITY)

        fun autoPreload(context: Context): Boolean =
            metaData(context)?.getBoolean(META_AUTO_PRELOAD, false) ?: false

        private fun metaData(context: Context) = runCatching {
            val ctx = context.applicationContext
            ctx.packageManager
                .getApplicationInfo(ctx.packageName, PackageManager.GET_META_DATA)
                .metaData
        }.getOrNull()

        private fun appVersionName(context: Context): String = runCatching {
            val ctx = context.applicationContext
            @Suppress("DEPRECATION")
            ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName.orEmpty()
        }.getOrNull().orEmpty().ifBlank { "0.0.0" }
    }
}
