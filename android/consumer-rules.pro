# §8.4 体验与性能 4
# jsBridge.postMessage 只被 JS 调用。没有这条规则，release 包里 R8 会把它
# 混淆或直接删掉，§3.1 的十个事件全部丢失，debug 包测不出来。
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
-keep class com.ssg.ssg_shell.JsBridge { *; }
