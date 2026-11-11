# §8.4 Performance 4.
# Only JavaScript calls jsBridge.postMessage. Without this rule, R8 may rename or remove it
# in release builds, losing all ten §3.1 events while debug builds still work.
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
-keep class com.ssg.ssg_shell.JsBridge { *; }
