plugins {
    alias(libs.plugins.kotlin.jvm)
    application
}

dependencies {
    implementation(project(":core"))
    implementation(project(":compat"))
    implementation(libs.dex2jar.translator)
    testImplementation(kotlin("test"))
    testImplementation(libs.okhttp.mockwebserver)
}

application {
    mainClass.set("com.gallery.reader.exthost.jvm.MainKt")
}

tasks.test {
    useJUnitPlatform()
    // Extension code is loaded unverified, as in the shipped host (see Main.kt).
    jvmArgs("-XX:+UnlockDiagnosticVMOptions", "-XX:-BytecodeVerificationRemote")
    systemProperty("exthost.testApks", rootProject.layout.projectDirectory.dir("testdata").asFile.path)
}

// One jar with the host and its libraries: what the app ships and starts.
val hostJar by tasks.registering(Jar::class) {
    archiveFileName.set("exthost.jar")
    destinationDirectory.set(rootProject.layout.buildDirectory.dir("dist"))
    manifest { attributes("Main-Class" to application.mainClass.get()) }
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    from(sourceSets.main.get().output)
    dependsOn(configurations.runtimeClasspath)
    from({ configurations.runtimeClasspath.get().filter { it.name.endsWith(".jar") }.map { zipTree(it) } }) {
        exclude("META-INF/*.SF", "META-INF/*.DSA", "META-INF/*.RSA", "META-INF/*.EC", "META-INF/versions/**", "module-info.class", "META-INF/maven/**")
    }
}
