#
# Native application shell for iOS. Pigeon generates the interface; section numbers refer to the shell integration specification.
# Validate changes with `pod lib lint ssg_shell.podspec`.
#
Pod::Spec.new do |s|
  s.name             = 'ssg_shell'
  s.version          = '1.0.2'
  s.summary          = 'Native IM shell with container injection, event bridging, OneSignal deep links, and liveness recovery.'
  s.description      = <<-DESC
The application combines a native shell with a WebView hosting the IM Web application.
The shell provides container injection (§1), URL and user-agent handling (§2), event bridging (§3 / §4),
push deep links (§5), permission timing (§6), WKWebView callbacks (§7), runtime configuration (§8),
navigation and startup (§9), and connection liveness and recovery (§10 / §11).
                       DESC
  s.homepage         = 'https://example.com/ssg-shell'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'SSG' => 'dev@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  # §7.3 PHPickerViewController requires iOS 14, as does
  # WKScriptMessageHandlerWithReply, used to return selected files to the page in chunks.
  s.platform = :ios, '14.0'
  s.frameworks = 'WebKit', 'PhotosUI', 'Photos', 'AVFoundation', 'Network', 'UserNotifications', 'ImageIO', 'UniformTypeIdentifiers'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.resource_bundles = {'ssg_shell_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
