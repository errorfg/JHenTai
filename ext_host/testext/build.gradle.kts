import java.util.Properties

plugins {
    alias(libs.plugins.kotlin.jvm)
}

// A test extension, built the way Tachiyomi extensions are: against the host's
// API (compile only), then converted to dex and packed with a binary manifest.
dependencies {
    compileOnly(project(":core"))
    compileOnly(project(":compat"))
}

fun androidSdk(): File {
    for (file in listOf(rootProject.file("local.properties"), rootProject.file("../android/local.properties"))) {
        if (file.isFile) {
            val dir = Properties().apply { file.inputStream().use(::load) }.getProperty("sdk.dir")
            if (dir != null) return File(dir)
        }
    }
    throw GradleException("Set sdk.dir in ext_host/local.properties to build the test extension")
}

// Writes jvm/src/test/resources/testext.apk. Needs the Android SDK's d8 and aapt2.
// Built for API 24 so d8 keeps interface default methods as they are; below 24
// it would route them through `$-CC` helper classes, which published
// extensions do not reference (they call Kotlin's DefaultImpls instead).
val testApk by tasks.registering {
    dependsOn(tasks.jar)
    val output = rootProject.file("jvm/src/test/resources/testext.apk")
    inputs.files(tasks.jar, file("src/main/res-manifest/AndroidManifest.xml"))
    outputs.file(output)
    doLast {
        val sdk = androidSdk()
        val buildTools = File(sdk, "build-tools").listFiles()!!.filter { File(it, "d8").exists() }.maxBy { it.name }
        val platform = File(sdk, "platforms").listFiles()!!.filter { File(it, "android.jar").exists() }.maxBy { it.name }
        val work = layout.buildDirectory.dir("apk").get().asFile.apply { deleteRecursively(); mkdirs() }
        val classpath = configurations.compileClasspath.get().files.flatMap { listOf("--classpath", it.path) }
        project.exec {
            commandLine(
                listOf(File(buildTools, "d8").path, "--release", "--min-api", "24", "--lib", File(platform, "android.jar").path) +
                    classpath + listOf("--output", work.path, tasks.jar.get().archiveFile.get().asFile.path),
            )
        }
        val unsigned = File(work, "base.apk")
        project.exec {
            commandLine(File(buildTools, "aapt2").path, "link", "-I", File(platform, "android.jar").path,
                "--manifest", file("src/main/res-manifest/AndroidManifest.xml").path, "-o", unsigned.path)
        }
        ant.withGroovyBuilder {
            "zip"("destfile" to unsigned.path, "update" to true) { "fileset"("dir" to work.path, "includes" to "classes.dex") }
        }
        unsigned.copyTo(output, overwrite = true)
    }
}
