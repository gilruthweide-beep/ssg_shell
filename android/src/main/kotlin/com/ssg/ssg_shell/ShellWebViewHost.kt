package com.ssg.ssg_shell

import android.view.View
import android.webkit.PermissionRequest
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebView

/**
 * Operations for which the WebView needs an Activity.
 *
 * Under §8.4, an application-level singleton owns the WebView; an Activity only attaches and detaches it.
 * Delegate these callbacks to the currently attached [ImActivity] instead of binding them permanently into the WebView.
 * The host is null during preloading or when IM is detached; callers provide their own fallbacks.
 */
internal interface ShellWebViewHost {

    /** §7.1 onShowFileChooser opens the §7.3 system photo picker. False means it could not open. */
    fun openPhotoPicker(
        params: WebChromeClient.FileChooserParams,
        callback: ValueCallback<Array<android.net.Uri>?>,
    ): Boolean

    /** §7.1 onPermissionRequest grants RESOURCE_AUDIO_CAPTURE, required for voice recording. */
    fun requestAudioPermission(request: PermissionRequest)

    /** §7.1 onPermissionRequestCanceled removes any remaining permission UI. */
    fun cancelPermissionRequest(request: PermissionRequest)

    /** §7.1 onShowCustomView presents fullscreen video. */
    fun showCustomView(view: View, callback: WebChromeClient.CustomViewCallback)

    /** §7.1 `onHideCustomView`. */
    fun hideCustomView()

    /** §7.1 Delegate URLs identified as external by shouldOverrideUrlLoading to the system. */
    fun openExternal(url: String): Boolean

    /** §7.1 `onCreateWindow`:`target="_blank"` / `window.open`. */
    fun openNewWindow(url: String?): Boolean

    /** §9.6 Show a native retry screen for initial-load or SSL failures instead of default WebView error UI. */
    fun showErrorPage(message: String?)

    /** Remove the retry screen after a successful load. */
    fun hideErrorPage()

    /** §9.6 Remove the splash immediately after `eventWebReady`. */
    fun dismissSplash(reason: ShellEventType)

    /** §11.2.3 Reattach the replacement WebView to the Activity after recreation. */
    fun onWebViewReplaced(webView: WebView)
}
