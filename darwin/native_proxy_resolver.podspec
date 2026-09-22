Pod::Spec.new do |s|
  s.name             = 'native_proxy_resolver'
  s.version          = '0.1.0'
  s.summary          = 'Per-URL system proxy resolution (PAC/WPAD) for Flutter on iOS and macOS.'
  s.description      = <<-DESC
Resolves the operating system proxy for a URL with CFNetwork, executing PAC
scripts, and reports network / proxy configuration changes.
                       DESC
  s.homepage         = 'https://github.com/Manish1Pandey/native_proxy_resolver'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Manish Kumar Panday' => 'https://github.com/Manish1Pandey' }
  s.source           = { :path => '.' }
  s.source_files     = 'native_proxy_resolver/Sources/native_proxy_resolver/**/*.swift'
  s.resource_bundles = { 'native_proxy_resolver_privacy' => ['native_proxy_resolver/Sources/native_proxy_resolver/Resources/PrivacyInfo.xcprivacy'] }
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
  s.frameworks = 'CFNetwork', 'Network'
  s.osx.frameworks = 'SystemConfiguration'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
