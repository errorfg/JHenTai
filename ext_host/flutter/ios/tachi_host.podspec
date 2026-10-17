# The extension host on iOS: OpenJDK (openjdk/mobile, Zero interpreter) linked
# statically into this framework, the host jar, and the runtime image. The
# OpenJDK parts are built by ext_host/ios/build-jdk.sh into jdk/ (not in git):
#   jdk/include/      jni.h and its iOS headers
#   jdk/lib/*.a       libjvm, the JDK's native libraries, libffi
#   jdk/home/lib/     the runtime image (jlink); HotSpot takes the folder
#                     "lib" next to the binary holding it as java.home
#   jdk/exthost.jar   ext_host/jvm's host jar
Pod::Spec.new do |s|
  s.name             = 'tachi_host'
  s.version          = '1.0.0'
  s.summary          = 'Runs Tachiyomi extensions inside the app.'
  s.homepage         = 'https://github.com/errorfg/JHenTai'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'JHenTai' => 'https://github.com/errorfg/JHenTai' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{h,m,cpp,swift}'
  s.public_header_files = 'Classes/ExtHostJVM.h'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.preserve_paths   = 'jdk/**/*'
  s.vendored_libraries = 'jdk/lib/*.a'
  s.resources        = ['jdk/home/lib', 'jdk/exthost.jar']
  s.libraries        = 'c++', 'z'
  s.frameworks       = 'Foundation', 'CFNetwork', 'Security', 'SystemConfiguration'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/jdk/include" "${PODS_TARGET_SRCROOT}/jdk/include/ios"',
    # Every object of the JDK's archives: the JVM finds native methods and
    # JNI_OnLoad_<library> by name at run time.
    'OTHER_LDFLAGS' => '-all_load',
    # The JDK is built for devices only.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64 x86_64',
  }
end
