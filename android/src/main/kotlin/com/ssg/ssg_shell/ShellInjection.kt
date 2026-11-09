package com.ssg.ssg_shell

import android.content.Context
import android.os.Build
import androidx.webkit.WebViewCompat

/** §1.1 / §11.5 组装注入对象和 UA 后缀。 */
internal object ShellInjection {

    /** §1.1 六个必填字段。缺 `platform` 视为注入无效，缺 `bundleId` 收不到推送。 */
    fun shellInfo(context: Context, shellVersion: String): ShellInfo = ShellInfo(
        platform = ShellPlatform.ANDROID,
        bundleId = context.applicationContext.packageName,
        shellVersion = shellVersion,
        webviewVersion = webViewVersionName(context),
        // §11.5 假死集中在特定厂商的省电策略上，没这两个字段没法按机型定位。
        deviceModel = Build.MODEL.orEmpty(),
        osVersion = Build.VERSION.RELEASE.orEmpty(),
    )

    fun webViewVersionName(context: Context): String = runCatching {
        WebViewCompat.getCurrentWebViewPackage(context.applicationContext)?.versionName
    }.getOrNull().orEmpty()

    fun webViewPackageName(context: Context): String = runCatching {
        WebViewCompat.getCurrentWebViewPackage(context.applicationContext)?.packageName
    }.getOrNull().orEmpty()

    /**
     * §1.2 注入脚本。必须用 `addDocumentStartJavaScript` 执行：
     * Web 侧有一组常量在模块加载那一刻求值，晚于首个 bundle 就无效，
     * `onPageStarted` 里的 `evaluateJavascript` 和首个 bundle 存在竞态，不接受。
     */
    fun buildScript(info: ShellInfo): String = buildString {
        append("window.__SSG_SHELL__={")
        append("platform:'").append(esc(info.platform.wire())).append("',")
        append("bundleId:'").append(esc(info.bundleId)).append("',")
        append("shellVersion:'").append(esc(info.shellVersion)).append("',")
        append("webviewVersion:'").append(esc(info.webviewVersion)).append("',")
        append("deviceModel:'").append(esc(info.deviceModel)).append("',")
        append("osVersion:'").append(esc(info.osVersion)).append("'")
        append("};")
    }

    /**
     * §2.2 UA 后缀。必须**追加**，不能整段替换 —— Web 与服务端都有按 UA 判平台的逻辑
     * （`Android`、`iPhone`、`iPad`），替换会让平台识别全面失效。
     */
    fun userAgentSuffix(shellVersion: String): String = " SSGShell/$shellVersion Android"

    private fun esc(value: String): String = value
        .replace("\\", "\\\\")
        .replace("'", "\\'")
        .replace("\n", " ")
        .replace("\r", " ")
        .replace("<", "\\u003c")

    private fun ShellPlatform.wire(): String = when (this) {
        ShellPlatform.ANDROID -> "android"
        ShellPlatform.IOS -> "ios"
    }
}
