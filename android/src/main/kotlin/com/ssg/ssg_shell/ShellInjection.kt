package com.ssg.ssg_shell

import android.content.Context
import android.os.Build
import androidx.webkit.WebViewCompat

/** §1.1 / §11.5 Build the injected object and user-agent suffix. */
internal object ShellInjection {

    /** §1.1 Six required fields. Missing platform invalidates injection; missing bundleId prevents push routing. */
    fun shellInfo(context: Context, shellVersion: String): ShellInfo = ShellInfo(
        platform = ShellPlatform.ANDROID,
        bundleId = context.applicationContext.packageName,
        shellVersion = shellVersion,
        webviewVersion = webViewVersionName(context),
        // §11.5 Device and OS fields help identify vendor-specific power-saving behavior behind unresponsive connections.
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
     * §1.2 Injection script. Execute with `addDocumentStartJavaScript`:
     * the Web application evaluates constants when its modules load, so injection after the first bundle is too late.
     * `evaluateJavascript` in `onPageStarted` races the first bundle and does not meet the contract.
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
     * §2.2 **Append** the user-agent suffix; do not replace the original agent. The Web and server detect platforms
     * from tokens such as `Android`, `iPhone`, and `iPad`, which a replacement agent could remove.
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
