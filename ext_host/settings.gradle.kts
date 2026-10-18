pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
        google()
    }
}

rootProject.name = "ext_host"

// compat: the Android classes extensions use, reimplemented for the JVM.
// core:   Tachiyomi's source API and the host itself; also compiled into the Android app.
// jvm:    the host program for desktop and iOS: dex conversion, class loading, entry point.
// testext: an extension used by the tests.
include(":compat", ":core", ":jvm", ":testext")
