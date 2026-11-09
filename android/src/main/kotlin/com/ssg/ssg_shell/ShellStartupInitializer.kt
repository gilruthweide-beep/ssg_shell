package com.ssg.ssg_shell

import android.content.Context
import android.util.Log
import androidx.lifecycle.ProcessLifecycleInitializer
import androidx.startup.AppInitializer
import androidx.startup.Initializer

/**
 * 进程启动即装配壳，不等 Flutter 引擎。
 *
 * 两条规范要求必须在这一刻生效：
 * - §8.4 体验与性能 1：B 面开启时就创建 WebView 并开始加载入口地址。WebView 内核首次
 *   初始化要几百毫秒，提前做能直接缩短冷启动。
 * - §11.1 / §11.2 / §11.4：心跳、存活监测、内存告警都挂在进程上。`ImActivity` 可以是
 *   冷启动的第一个 Activity（§8.4 体验与性能 2），那时 Dart 还没上线，这些不能等它。
 *
 * 配置来自宿主 Manifest 的 `<meta-data>` 加落盘缓存（见 [ShellConfig.fromDisk]）：
 *
 * ```xml
 * <meta-data android:name="com.ssg.shell.ENTRY_URL"     android:value="https://im.example.com/" />
 * <meta-data android:name="com.ssg.shell.CHANNEL_CODE"  android:value="ch001" />
 * <meta-data android:name="com.ssg.shell.A_SIDE_ACTIVITY" android:value="com.example.app.MainActivity" />
 * <meta-data android:name="com.ssg.shell.AUTO_PRELOAD"  android:value="true" />
 * ```
 */
class ShellStartupInitializer : Initializer<Unit> {

    override fun create(context: Context) {
        ShellCore.attach(context)
        PermissionCoordinator.attach(context)

        // §8.4 体验与性能 1：「B 面未开启时不要预加载 IM」—— 这个判断在 ShellCore.preload()
        // 里，这里只决定要不要让插件自己发起。宿主想完全自己掌握时机就把 AUTO_PRELOAD 留空。
        if (!ShellConfig.autoPreload(context)) return
        if (ShellCore.config().entryUrl.isBlank()) {
            Log.w(
                TAG,
                "AUTO_PRELOAD 已开启，但 entryUrl 为空：在 Manifest 里给 " +
                    "com.ssg.shell.ENTRY_URL，或先让 Dart 调一次 initialize()。",
            )
            return
        }
        ShellCore.preload()
    }

    /** 前后台判定依赖 ProcessLifecycleOwner，它得先初始化完（§4 / §10.2）。 */
    override fun dependencies(): List<Class<out Initializer<*>>> =
        listOf(ProcessLifecycleInitializer::class.java)

    internal companion object {
        private const val TAG = "SsgShell"

        /**
         * 宿主用 `tools:node="remove"` 去掉了 Manifest 里的自动初始化时，插件自己补一次。
         * [AppInitializer] 保证同一个 Initializer 只会跑一遍。
         */
        fun ensure(context: Context) {
            runCatching {
                AppInitializer.getInstance(context.applicationContext)
                    .initializeComponent(ShellStartupInitializer::class.java)
            }.onFailure {
                // androidx.startup 的 provider 被移掉时会抛，退化成直接装配。
                ShellCore.attach(context)
                PermissionCoordinator.attach(context)
            }
        }
    }
}
