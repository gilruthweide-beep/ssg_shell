package com.ssg.ssg_shell

import android.webkit.JavascriptInterface

/**
 * §3.3 Web → Native channel.
 *
 * The object must be jsBridge and its method postMessage. The Web application first tries the two-argument overload,
 * then falls back to one argument on errors, so **the two-argument overload is required**.
 *
 * R8 treats JavaScript-only methods as dead code; release builds would lose events while debug builds appear correct.
 * The matching keep rule is in consumer-rules.pro; see §8.4 Performance 4.
 */
internal class JsBridge(private val sink: (WebEvent) -> Unit) {

    /** Two-argument overload: handler name (such as eventLogin), then JSON payload. */
    @JavascriptInterface
    fun postMessage(name: String?, json: String?) {
        // Called on the JavaScript thread. Do not access WebView here; the sink dispatches to the main thread.
        WebEventParser.parse(name, json)?.let(sink)
    }

    /** One-argument overload: infer the event only from the payload eventName field. */
    @JavascriptInterface
    fun postMessage(json: String?) {
        WebEventParser.parse(null, json)?.let(sink)
    }

    internal companion object {
        /** §1.4 The Web application detects this exact name as a container fallback; preserve it. */
        const val NAME = "jsBridge"
    }
}
