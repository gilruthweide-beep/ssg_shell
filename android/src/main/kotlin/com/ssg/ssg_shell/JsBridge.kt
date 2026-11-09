package com.ssg.ssg_shell

import android.webkit.JavascriptInterface

/**
 * §3.3 Web → Native 通道。
 *
 * 对象名必须是 `jsBridge`，方法名必须是 `postMessage`。Web 优先调两参版本，抛异常时
 * 退化为单参版本，所以**两参必须实现**。
 *
 * R8 会把只被 JS 调用的方法当成死代码，release 包里事件会全丢（debug 包测不出来）。
 * `consumer-rules.pro` 里有对应的 keep 规则，见 §8.4 体验与性能 4。
 */
internal class JsBridge(private val sink: (WebEvent) -> Unit) {

    /** 两参版本：第一个参数是 handler 名（`eventLogin`），第二个是 JSON payload。 */
    @JavascriptInterface
    fun postMessage(name: String?, json: String?) {
        // JS 线程上调过来，不要在这里碰 WebView。sink 内部负责切主线程。
        WebEventParser.parse(name, json)?.let(sink)
    }

    /** 单参版本：事件名只能从 payload 的 `eventName` 里取。 */
    @JavascriptInterface
    fun postMessage(json: String?) {
        WebEventParser.parse(null, json)?.let(sink)
    }

    internal companion object {
        /** §1.4 Web 对这个名字做存在性兜底识别，不能改。 */
        const val NAME = "jsBridge"
    }
}
