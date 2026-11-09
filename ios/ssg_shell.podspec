#
# 马甲包原生壳（iOS）。接口由 Pigeon 生成，条款编号对应 docs/马甲包对接规范.md。
# 改完用 `pod lib lint ssg_shell.podspec` 过一遍。
#
Pod::Spec.new do |s|
  s.name             = 'ssg_shell'
  s.version          = '1.0.2'
  s.summary          = '马甲包原生壳：容器注入、事件通道、OneSignal 深链、假死防护。'
  s.description      = <<-DESC
App = 原生壳 + WebView 加载 IM Web。壳负责容器注入（§1）、URL 与 UA（§2）、
事件通道（§3 / §4）、推送深链（§5）、权限时机（§6）、WKWebView 回调（§7）、
运行环境（§8）、交互与启动（§9）、保活与假死防护（§10 / §11）。
                       DESC
  s.homepage         = 'https://example.com/ssg-shell'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'SSG' => 'dev@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  # §7.3 PHPickerViewController 要 iOS 14；同一版本起才有
  # WKScriptMessageHandlerWithReply（分块把文件交回页面要用）。
  s.platform = :ios, '14.0'
  s.frameworks = 'WebKit', 'PhotosUI', 'Photos', 'AVFoundation', 'Network', 'UserNotifications', 'ImageIO', 'UniformTypeIdentifiers'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.resource_bundles = {'ssg_shell_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
