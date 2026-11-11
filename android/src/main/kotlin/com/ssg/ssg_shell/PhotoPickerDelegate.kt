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
 * §7.3 Photo picker.
 *
 * Open the system photo picker directly without intermediate file, camera, or video-recording menus.
 *
 * Three pitfalls called out in the specification:
 * 1. Avoid fileChooserParams.createIntent(), which opens a document picker.
 * 2. Use the multiple-selection launcher for MODE_OPEN_MULTIPLE. It must also allow confirming a single selection;
 *    do not require two selections or restrict this mode to one selection.
 * 3. **Cancellation must call onReceiveValue(null).** Otherwise WebView keeps waiting for the previous result,
 *    and subsequent attachment taps become permanently unresponsive.
 *
 * Register both ActivityResultLaunchers in onCreate, before the Activity
 * reaches STARTED.
 */
internal class PhotoPickerDelegate(activity: ComponentActivity) {

    /** WebView allows only one pending file selection request at a time. */
    private var pending: ValueCallback<Array<Uri>?>? = null

    private val singleLauncher = activity.registerForActivityResult(PickVisualMedia()) { uri ->
        // A null URI on cancellation must produce a null callback result (§7.3.3).
        deliver(if (uri == null) null else arrayOf(uri))
    }

    private val multipleLauncher = activity.registerForActivityResult(
        PickMultipleVisualMedia(maxItems()),
    ) { uris ->
        // An empty selection list on cancellation also produces a null callback result.
        deliver(if (uris.isEmpty()) null else uris.toTypedArray())
    }

    /**
     * @return False if this device cannot open a photo picker; the caller must return null to WebView.
     */
    fun launch(
        params: WebChromeClient.FileChooserParams,
        callback: ValueCallback<Array<Uri>?>,
    ): Boolean {
        // Release any previous pending request first, even though WebView normally serializes them;
        // leaving a callback unresolved would disable subsequent attachment selections.
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
            Log.e(TAG, "Unable to open the system photo picker", it)
            pending = null
        }.getOrDefault(false)
    }

    private fun deliver(uris: Array<Uri>?) {
        val callback = pending ?: return
        pending = null
        callback.onReceiveValue(uris)
    }

    /** Release pending requests when the Activity is destroyed so WebView does not wait forever. */
    fun dispose() {
        deliver(null)
    }

    /**
     * §7.3.1 Filter the photo picker according to `accept`.
     *
     * - Attachments accepting both image and video types: show both in the same picker.
     * - Avatar selection accepting only images: show images only.
     * - Narrower group or private-chat restrictions: apply the supplied accept filter.
     *
     * The Web application supplies concrete MIME types such as image/png,image/jpeg,video/mp4,
     * so classify them by prefix rather than requiring wildcard types.
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

        // A single concrete accept type permits exact photo-picker filtering.
        val concrete = types.filterNot { it.endsWith("/*") }
        if (concrete.size == 1 && (hasImage || hasVideo)) {
            return PickVisualMedia.SingleMimeType(concrete.first())
        }

        return when {
            hasImage && hasVideo -> PickVisualMedia.ImageAndVideo
            hasImage -> PickVisualMedia.ImageOnly
            hasVideo -> PickVisualMedia.VideoOnly
            // If accept contains neither images nor videos, use the attachment default; the Web application does not send documents (§6.1).
            else -> PickVisualMedia.ImageAndVideo
        }
    }

    private companion object {
        const val TAG = "SsgShell"

        /**
         * §7.3.2 PickMultipleVisualMedia requires a selection limit greater than one,
         * and no larger than the system maximum, otherwise it throws IllegalArgumentException.
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
