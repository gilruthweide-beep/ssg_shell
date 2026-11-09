package com.ssg.ssg_shell

import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import androidx.activity.ComponentActivity
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts.PickMultipleVisualMedia
import androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia

/**
 * §7.3 文件选择器。
 *
 * 点附件直接进入系统相册，中间不出现任何选择菜单（「文件」「拍照」「录制视频」都不要）。
 *
 * 规范点名的三个坑：
 * 1. 不要用 `fileChooserParams.createIntent()` —— 它打开的是文档选择器。
 * 2. `MODE_OPEN_MULTIPLE` 时用多选版本，多选版本里只选一张也能直接确认，
 *    不要求至少选两张；不要限制成只能单选。
 * 3. **用户取消时必须回调 `onReceiveValue(null)`。** 漏了这一步，此后点附件按钮
 *    永久无反应 —— WebView 在等上一次的结果，不会再发起新的请求。
 *
 * 两个 launcher 都在 `onCreate` 里注册：`ActivityResultLauncher` 必须在 Activity
 * 到达 STARTED 之前注册完。
 */
internal class PhotoPickerDelegate(activity: ComponentActivity) {

    /** 同一时刻只会有一个待处理的选择请求（WebView 的约定）。 */
    private var pending: ValueCallback<Array<Uri>?>? = null

    private val singleLauncher = activity.registerForActivityResult(PickVisualMedia()) { uri ->
        // 取消时 uri 为 null → 必须回 null，见 §7.3.3。
        deliver(if (uri == null) null else arrayOf(uri))
    }

    private val multipleLauncher = activity.registerForActivityResult(
        PickMultipleVisualMedia(maxItems()),
    ) { uris ->
        // 取消时是空列表 → 同样必须回 null。
        deliver(if (uris.isEmpty()) null else uris.toTypedArray())
    }

    /**
     * @return false 表示拉不起来（设备不支持照片选择器），调用方要负责回调 null。
     */
    fun launch(
        params: WebChromeClient.FileChooserParams,
        callback: ValueCallback<Array<Uri>?>,
    ): Boolean {
        // 上一次请求还挂着（理论上不会，WebView 会串行）：先把它放掉，
        // 不然那个 callback 永远不回，附件按钮就死了。
        pending?.onReceiveValue(null)
        pending = callback

        val request = PickVisualMediaRequest.Builder()
            .setMediaType(mediaTypeOf(params.acceptTypes))
            .build()

        val multiple =
            params.mode == WebChromeClient.FileChooserParams.MODE_OPEN_MULTIPLE
        return runCatching {
            if (multiple) multipleLauncher.launch(request) else singleLauncher.launch(request)
            true
        }.onFailure {
            Log.e(TAG, "拉起系统照片选择器失败", it)
            pending = null
        }.getOrDefault(false)
    }

    private fun deliver(uris: Array<Uri>?) {
        val callback = pending ?: return
        pending = null
        callback.onReceiveValue(uris)
    }

    /** Activity 被销毁时放掉挂着的请求，避免 WebView 永久等待。 */
    fun dispose() {
        deliver(null)
    }

    /**
     * §7.3.1 按 `accept` 决定相册里显示什么。
     *
     * - 附件（`acceptTypes` 里图片和视频的通配类型都有）→ 两者在同一个相册里选
     * - 改头像（只有图片）→ 只显示图片
     * - 群或私聊限制发送类型时 `accept` 会收窄，照此收窄
     *
     * Web 侧实际发下来的是具体类型（`image/png,image/jpeg,video/mp4,...`），
     * 不是通配类型，所以按前缀归类。
     */
    private fun mediaTypeOf(acceptTypes: Array<String>?): PickVisualMedia.VisualMediaType {
        val types = acceptTypes
            ?.flatMap { it.split(',') }
            ?.map { it.trim().lowercase() }
            ?.filter { it.isNotEmpty() && it != "*/*" }
            .orEmpty()

        if (types.isEmpty()) return PickVisualMedia.ImageAndVideo

        val hasImage = types.any { it.startsWith("image/") }
        val hasVideo = types.any { it.startsWith("video/") }

        // 收窄到单一具体类型时，照片选择器能精确过滤。
        val concrete = types.filterNot { it.endsWith("/*") }
        if (concrete.size == 1 && (hasImage || hasVideo)) {
            return PickVisualMedia.SingleMimeType(concrete.first())
        }

        return when {
            hasImage && hasVideo -> PickVisualMedia.ImageAndVideo
            hasImage -> PickVisualMedia.ImageOnly
            hasVideo -> PickVisualMedia.VideoOnly
            // accept 里没有图片也没有视频：Web 不发文件（§6.1），按附件默认处理。
            else -> PickVisualMedia.ImageAndVideo
        }
    }

    private companion object {
        const val TAG = "SsgShell"

        /**
         * §7.3.2 多选上限。`PickMultipleVisualMedia` 要求 > 1，
         * 且不能超过系统上限，否则直接抛 IllegalArgumentException。
         */
        fun maxItems(): Int {
            val systemLimit = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                runCatching { MediaStore.getPickImagesMaxLimit() }.getOrDefault(DEFAULT_MAX)
            } else {
                DEFAULT_MAX
            }
            return systemLimit.coerceIn(2, DEFAULT_MAX)
        }

        const val DEFAULT_MAX = 30
    }
}
