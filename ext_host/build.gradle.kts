plugins {
    alias(libs.plugins.kotlin.jvm) apply false
}

// Java 17 bytecode, built with whichever JDK 17 or later runs Gradle.
subprojects {
    plugins.withId("org.jetbrains.kotlin.jvm") {
        extensions.configure<org.jetbrains.kotlin.gradle.dsl.KotlinJvmProjectExtension> {
            compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
        tasks.withType<JavaCompile>().configureEach { options.release.set(17) }
    }
}
