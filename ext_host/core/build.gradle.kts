plugins {
    alias(libs.plugins.kotlin.jvm)
}

dependencies {
    // On Android these classes come from the platform and androidx.preference.
    compileOnly(project(":compat"))
    api(libs.okhttp)
    api(libs.jsoup)
    api(libs.serialization.json)
    api(libs.serialization.json.okio)
    api(libs.coroutines.core)
    api(libs.rxjava)
}
