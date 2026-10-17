plugins {
    alias(libs.plugins.kotlin.jvm)
}

dependencies {
    implementation(libs.serialization.json)
    implementation(libs.jsoup)
    implementation(libs.okhttp)
}
