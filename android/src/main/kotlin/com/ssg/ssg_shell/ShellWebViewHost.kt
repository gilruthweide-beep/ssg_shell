package com.ssg.ssg_shell

import android.view.View
import android.webkit.PermissionRequest
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebView

/**
 * WebView 需要 Activity 才能完成的事。
 *
 * WebView 本身按 §8.4 由 Application 级单例持有，Activity 只负责挂上和取下，
 * 所以这些回调不能写死在 WebView 里，要由当前挂载的 [ImActivity] 实现。
 * 没有 Activity 挂载时（预加载阶段、IM 页在后台）实现为 null，各处自行降级。
 */
internal interface ShellWebViewHost {

    /** §7.1 `onShowFileChooser` → §7.3 系统照片选择器。返回 false 表示拉不起来。 */
    fun openPhotoPicker(
        params: WebChromeClient.FileChooserParams,
        callback: ValueCallback<Array<android.net.Uri>?>,
    ): Boolean

    /** §7.1 `onPermissionRequest`：授予 `RESOURCE_AUDIO_CAPTURE`，不给语音录不了。 */
    fun requestAudioPermission(request: PermissionRequest)

    /** §7.1 `onPermissionRequestCanceled`：清理授权 UI，不然残留弹窗。 */
    fun cancelPermissionRequest(request: PermissionRequest)

    /** §7.1 `onShowCustomView`：视频全屏。 */
    fun showCustomView(view: View, callback: WebChromeClient.CustomViewCallback)

    /** §7.1 `onHideCustomView`。 */
    fun hideCustomView()

    /** §7.1 `shouldOverrideUrlLoading` 判定为外链后交给系统。 */
    fun openExternal(url: String): Boolean

    /** §7.1 `onCreateWindow`：`target="_blank"` / `window.open`。 */
    fun openNewWindow(url: String?): Boolean

    /** §9.6 首屏加载失败 / SSL 错误 → 原生重试页，不要露出 WebView 默认错误页。 */
    fun showErrorPage(message: String?)

    /** 加载成功后撤掉重试页。 */
    fun hideErrorPage()

    /** §9.6 收到 `eventWebReady` 后立即撤 splash。 */
    fun dismissSplash(reason: ShellEventType)

    /** §11.2.3 WebView 实例被换掉后，Activity 需要重新挂上新实例。 */
    fun onWebViewReplaced(webView: WebView)
}
