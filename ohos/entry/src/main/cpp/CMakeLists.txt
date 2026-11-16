cmake_minimum_required(VERSION 3.5.0)
project(exthost C)

# The bridge to the JVM that runs the Tachiyomi extension host. The VM itself
# (libjdkhost.so: OpenJDK's Zero VM and java.base's native libraries) is not
# built here; it is loaded at run time when the package carries it.
add_library(exthost SHARED exthost.c)
# jni.h and jni_md.h of the JDK the VM was built from, copied in by the build.
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/jdk/include/jni.h)
  target_include_directories(exthost PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/jdk/include)
  target_compile_definitions(exthost PRIVATE EXTHOST_HAS_JDK)
endif()
target_link_libraries(exthost PUBLIC libace_napi.z.so libhilog_ndk.z.so)
