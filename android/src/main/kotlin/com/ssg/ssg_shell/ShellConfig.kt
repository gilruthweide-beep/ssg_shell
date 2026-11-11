package com.ssg.ssg_shell

import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri

/**
 * Shell runtime configuration.
 *
 * Merge two configuration sources in priority order:
 *  1. [ShellConfigDto] supplied by Dart through [SsgShellHostApi.initialize].
 *  2. Host Manifest `<meta-data>`.
 *
 * Both sources are required because §8.4 Performance 2 allows ImActivity to be the first
 * cold-start Activity before Flutter starts. That path cannot read Dart configuration and instead uses Manifest values
 * with persisted cache values, as required by §9.6.
 */
internal data class ShellConfig(
    /** §2.1 Complete landing URL, loaded unchanged; the Web application reads its optional channel code. */
    val entryUrl: String,
    /** Ignored legacy compatibility field; it does not affect URL loading or attribution. */
    val channelCode: String = "",
    /** §1.1 / §2.2 Shell version. */
    val shellVersion: String,
    /** §9.6 B-side switch. */
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
    /** §2.1 Return the complete landing URL unchanged without rebuilding its query. */
    fun resolvedUrl(): String = entryUrl

    /** §10.5 IM host used by §7.1 to identify external links. */
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

        /** Read Manifest metadata and persisted cache values before Dart is available. */
        fun fromDisk(context: Context): ShellConfig {
            val meta = metaData(context)
            val prefs = context.applicationContext
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val metaEntry = meta?.getString(META_ENTRY_URL).orEmpty()
            val metaVersion = meta?.getString(META_SHELL_VERSION).orEmpty()
            return ShellConfig(
                // The persisted complete landing URL takes priority, including its optional channel code.
                entryUrl = prefs.getString(KEY_ENTRY_URL, null) ?: metaEntry,
                shellVersion = prefs.getString(KEY_SHELL_VERSION, null)
                    ?: metaVersion.ifBlank { appVersionName(context) },
                // §9.6 Default to disabled without a cache; do not open B side before it has been enabled.
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

        /** §11.7 Show outdated-engine guidance once and respect dismissal. */
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
