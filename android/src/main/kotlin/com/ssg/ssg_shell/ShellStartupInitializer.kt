package com.ssg.ssg_shell

import android.content.Context
import android.util.Log
import androidx.lifecycle.ProcessLifecycleInitializer
import androidx.startup.AppInitializer
import androidx.startup.Initializer

/**
 * Initialize the shell at process startup without waiting for the Flutter engine.
 *
 * Two specification requirements apply immediately:
 * - §8.4 Performance 1: create the WebView and load the landing URL when B side is enabled. Initial engine startup
 *   can take hundreds of milliseconds; doing it early reduces cold-start latency.
 * - §11.1 / §11.2 / §11.4: heartbeat, liveness monitoring, and memory warnings belong to the process. `ImActivity` may
 *   be the first cold-start Activity (§8.4 Performance 2), so these cannot wait for Dart.
 *
 * Configuration combines host Manifest `<meta-data>` with persisted cache values (see [ShellConfig.fromDisk]):
 *
 * ```xml
 * <meta-data android:name="com.ssg.shell.ENTRY_URL"     android:value="https://im.example.com/?channelcode=ch001" />
 * <meta-data android:name="com.ssg.shell.A_SIDE_ACTIVITY" android:value="com.example.app.MainActivity" />
 * <meta-data android:name="com.ssg.shell.AUTO_PRELOAD"  android:value="true" />
 * ```
 */
class ShellStartupInitializer : Initializer<Unit> {

    override fun create(context: Context) {
        ShellCore.attach(context)
        PermissionCoordinator.attach(context)

        // §8.4 Performance 1: ShellCore.preload() already prevents IM preloading when B side is disabled.
        // This controls automatic plugin preloading; hosts that manage timing themselves can omit AUTO_PRELOAD.
        if (!ShellConfig.autoPreload(context)) return
        if (ShellCore.config().entryUrl.isBlank()) {
            Log.w(
                TAG,
                "AUTO_PRELOAD is enabled, but entryUrl is empty. Set Manifest metadata" +
                    " com.ssg.shell.ENTRY_URL or call initialize() from Dart first.",
            )
            return
        }
        ShellCore.preload()
    }

    /** Foreground tracking requires ProcessLifecycleOwner to initialize first (§4 / §10.2). */
    override fun dependencies(): List<Class<out Initializer<*>>> =
        listOf(ProcessLifecycleInitializer::class.java)

    internal companion object {
        private const val TAG = "SsgShell"

        /**
         * If the host removed automatic Manifest initialization with `tools:node="remove"`, initialize from the plugin instead.
         * [AppInitializer] guarantees that each Initializer runs only once.
         */
        fun ensure(context: Context) {
            runCatching {
                AppInitializer.getInstance(context.applicationContext)
                    .initializeComponent(ShellStartupInitializer::class.java)
            }.onFailure {
                // If the androidx.startup provider was removed, fall back to direct initialization.
                ShellCore.attach(context)
                PermissionCoordinator.attach(context)
            }
        }
    }
}
