# On macOS the extension host runs as a child process on the runtime the app
# bundles (ext_host/desktop/package.sh); this pod only lends it WKWebView.
# Classes/TachiBrowser.swift links to the iOS copy.
Pod::Spec.new do |s|
  s.name             = 'tachi_host'
  s.version          = '1.0.0'
  s.summary          = 'Lends the extension host WKWebView.'
  s.homepage         = 'https://github.com/errorfg/JHenTai'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'JHenTai' => 'https://github.com/errorfg/JHenTai' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '10.15'
  s.swift_version    = '5.0'
  s.frameworks       = 'WebKit'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
