package com.gallery.reader.exthost.extension

import com.gallery.reader.exthost.HostPlatform
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.ConfigurableSource
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.zip.ZipFile

class SourceInfo(
    val id: Long,
    val name: String,
    val lang: String,
    val baseUrl: String?,
    val supportsLatest: Boolean,
    val configurable: Boolean,
) {
    fun toJson(): JsonObject =
        buildJsonObject {
            put("id", id.toString())
            put("name", name)
            put("lang", lang)
            put("baseUrl", baseUrl)
            put("supportsLatest", supportsLatest)
            put("configurable", configurable)
        }

    companion object {
        fun fromJson(json: JsonObject) =
            SourceInfo(
                id = json["id"]!!.jsonPrimitive.content.toLong(),
                name = json["name"]!!.jsonPrimitive.content,
                lang = json["lang"]!!.jsonPrimitive.content,
                baseUrl = (json["baseUrl"] as? JsonPrimitive)?.takeIf { it.isString }?.content,
                supportsLatest = json["supportsLatest"]!!.jsonPrimitive.boolean,
                configurable = json["configurable"]!!.jsonPrimitive.boolean,
            )

        fun of(source: Source) =
            SourceInfo(
                id = source.id,
                name = source.name,
                lang = source.lang,
                baseUrl = (source as? HttpSource)?.let { runCatching { it.baseUrl }.getOrNull() },
                supportsLatest = source.supportsLatest,
                configurable = source is ConfigurableSource,
            )
    }
}

class InstalledExtension(
    val pkg: String,
    val name: String,
    val versionName: String,
    val versionCode: Long,
    val libVersion: String,
    val nsfw: Boolean,
    val sources: List<SourceInfo>,
) {
    fun toJson(): JsonObject =
        buildJsonObject {
            put("pkg", pkg)
            put("name", name)
            put("versionName", versionName)
            put("versionCode", versionCode)
            put("libVersion", libVersion)
            put("nsfw", nsfw)
            put("sources", JsonArray(sources.map { it.toJson() }))
        }

    companion object {
        fun fromJson(json: JsonObject) =
            InstalledExtension(
                pkg = json["pkg"]!!.jsonPrimitive.content,
                name = json["name"]!!.jsonPrimitive.content,
                versionName = json["versionName"]!!.jsonPrimitive.content,
                versionCode = json["versionCode"]!!.jsonPrimitive.long,
                libVersion = json["libVersion"]!!.jsonPrimitive.content,
                nsfw = json["nsfw"]!!.jsonPrimitive.boolean,
                sources = json["sources"]!!.jsonArray.map { SourceInfo.fromJson(it.jsonObject) },
            )
    }
}

class ExtensionException(
    message: String,
) : Exception(message)

/**
 * Installed extensions, one directory each under `<dataDir>/extensions/<pkg>`:
 * the APK as installed, `meta.json` (what the app lists without loading any
 * code) and `icon.png`, plus whatever the platform prepared (the JVM's
 * converted classes). Code is loaded the first time one of its sources is used.
 */
class ExtensionStore(
    private val platform: HostPlatform,
) {
    private val root = File(platform.dataDir, "extensions").apply { mkdirs() }
    private val installed = ConcurrentHashMap<String, InstalledExtension>()
    private val sourcePackage = ConcurrentHashMap<Long, String>()
    private val loaded = ConcurrentHashMap<String, Loaded>()

    /** Code kept open after [refresh], for the next source objects of the same extension. */
    private val retained = ConcurrentHashMap<String, ClassLoader>()

    private class Loaded(
        val loader: ClassLoader,
        val sources: Map<Long, Source>,
    )

    init {
        root.listFiles()?.filter { it.isDirectory && !it.name.startsWith(".") }?.forEach { dir ->
            try {
                register(InstalledExtension.fromJson(Json.parseToJsonElement(File(dir, META).readText()).jsonObject))
            } catch (e: Exception) {
                platform.log("skipping ${dir.name}: $e")
            }
        }
    }

    private fun register(extension: InstalledExtension) {
        installed[extension.pkg] = extension
        extension.sources.forEach { sourcePackage[it.id] = extension.pkg }
    }

    fun list(): List<InstalledExtension> = installed.values.sortedBy { it.name.lowercase() }

    /** The extension's icon, taken from its APK the first time if needed. */
    fun icon(pkg: String): File? {
        val dir = File(root, pkg)
        val icon = File(dir, ICON)
        val apk = File(dir, APK)
        if (!icon.isFile && apk.isFile) runCatching { extractIcon(apk, icon) }
        return icon.takeIf { it.isFile }
    }

    fun extensionOf(sourceId: Long): InstalledExtension? = sourcePackage[sourceId]?.let { installed[it] }

    /** Installs or replaces the extension in [apk], which is copied; the original is left alone. */
    @Synchronized
    fun install(apk: File): InstalledExtension {
        val manifest =
            ZipFile(apk).use { zip ->
                val entry = zip.getEntry("AndroidManifest.xml") ?: throw ExtensionException("not an APK: no AndroidManifest.xml")
                ApkManifest.parse(zip.getInputStream(entry).readBytes())
            }
        if (EXTENSION_FEATURE !in manifest.features) throw ExtensionException("${manifest.packageName} is not a Tachiyomi extension")
        val libVersion = manifest.versionName.substringBeforeLast('.')
        val lib = libVersion.toDoubleOrNull() ?: throw ExtensionException("unknown extension library version ${manifest.versionName}")
        if (lib < LIB_VERSION_MIN || lib > LIB_VERSION_MAX) {
            throw ExtensionException("extension library $libVersion is not supported (supported: $LIB_VERSION_MIN to $LIB_VERSION_MAX)")
        }
        val pkg = manifest.packageName
        val classes = manifest.metaData[METADATA_SOURCE_CLASS] ?: throw ExtensionException("$pkg declares no source class")

        val staging = File(root, ".staging-$pkg").apply { deleteRecursively(); mkdirs() }
        try {
            val stagedApk = File(staging, APK)
            apk.copyTo(stagedApk, overwrite = true)
            platform.prepare(stagedApk, staging)
            val loader = platform.classLoader(stagedApk, staging)
            // Read what the app lists while the code can still load classes.
            val sources =
                try {
                    instantiate(pkg, classes, loader).map(SourceInfo::of)
                } finally {
                    platform.releaseClassLoader(loader)
                }
            if (sources.isEmpty()) throw ExtensionException("$pkg has no sources")
            val extension =
                InstalledExtension(
                    pkg = pkg,
                    name = (manifest.label ?: pkg.substringAfterLast('.')).removePrefix("Tachiyomi: "),
                    versionName = manifest.versionName,
                    versionCode = manifest.versionCode,
                    libVersion = libVersion,
                    nsfw = manifest.metaData[METADATA_NSFW] == "1",
                    sources = sources,
                )
            File(staging, META).writeText(extension.toJson().toString())
            extractIcon(stagedApk, File(staging, ICON))

            unload(pkg)
            installed.remove(pkg)?.sources?.forEach { sourcePackage.remove(it.id) }
            val dir = File(root, pkg)
            dir.deleteRecursively()
            if (!staging.renameTo(dir)) throw ExtensionException("cannot move $pkg into place")
            register(extension)
            platform.log("installed $pkg ${manifest.versionName}: ${extension.sources.joinToString { it.name }}")
            return extension
        } finally {
            staging.deleteRecursively()
        }
    }

    @Synchronized
    fun uninstall(pkg: String) {
        unload(pkg)
        installed.remove(pkg)?.sources?.forEach { sourcePackage.remove(it.id) }
        File(root, pkg).deleteRecursively()
    }

    /** Drops the loaded code of [pkg]; the next use loads it again. */
    fun unload(pkg: String) {
        loaded.remove(pkg)?.let { platform.releaseClassLoader(it.loader) }
        retained.remove(pkg)?.let(platform::releaseClassLoader)
    }

    /**
     * Drops the source objects of [pkg] after its settings changed (sources
     * read them when created); the next use creates fresh ones from the same
     * code. The code stays open: a change may have started work that is
     * still loading classes, such as a login in a WebView on its own thread.
     */
    fun refresh(pkg: String) {
        loaded.remove(pkg)?.let { retained.putIfAbsent(pkg, it.loader) }
    }

    fun source(id: Long): CatalogueSource {
        val pkg = sourcePackage[id] ?: throw ExtensionException("no installed extension has source $id")
        val source = (loaded[pkg] ?: load(pkg)).sources[id] ?: throw ExtensionException("source $id is gone from $pkg; reinstall it")
        return source as? CatalogueSource ?: throw ExtensionException("source $id cannot be browsed")
    }

    @Synchronized
    private fun load(pkg: String): Loaded {
        loaded[pkg]?.let { return it }
        val dir = File(root, pkg)
        val apk = File(dir, APK)
        val classes =
            ZipFile(apk).use { zip ->
                ApkManifest.parse(zip.getInputStream(zip.getEntry("AndroidManifest.xml")).readBytes()).metaData[METADATA_SOURCE_CLASS]
            } ?: throw ExtensionException("$pkg declares no source class")
        val loader = retained.remove(pkg) ?: platform.classLoader(apk, dir)
        val started = System.currentTimeMillis()
        val sources = instantiate(pkg, classes, loader).associateBy { it.id }
        platform.log("loaded $pkg in ${System.currentTimeMillis() - started} ms")
        return Loaded(loader, sources).also { loaded[pkg] = it }
    }

    private fun instantiate(
        pkg: String,
        classes: String,
        loader: ClassLoader,
    ): List<Source> =
        classes
            .split(';')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .flatMap { name ->
                val className = if (name.startsWith(".")) pkg + name else name
                val instance =
                    try {
                        Class.forName(className, false, loader).getDeclaredConstructor().newInstance()
                    } catch (e: ReflectiveOperationException) {
                        throw ExtensionException("cannot create $className: ${e.cause ?: e}")
                    } catch (e: LinkageError) {
                        throw ExtensionException("cannot load $className: $e")
                    }
                when (instance) {
                    is SourceFactory -> instance.createSources()
                    is Source -> listOf(instance)
                    else -> throw ExtensionException("$className is not a source")
                }
            }

    // The launcher icon: the largest ic_launcher PNG among the mipmap folders.
    // Shrunk APKs rename resources (res/Ab.png); their PNGs are the launcher
    // icon in its sizes, so then the largest PNG.
    private fun extractIcon(
        apk: File,
        target: File,
    ) {
        ZipFile(apk).use { zip ->
            val pngs = zip.entries().asSequence().filter { it.name.startsWith("res/") && it.name.endsWith(".png") }.toList()
            val entry =
                pngs
                    .filter { it.name.substringAfterLast('/').startsWith("ic_launcher") }
                    .filterNot { it.name.contains("foreground") || it.name.contains("background") }
                    .maxByOrNull { it.size }
                    ?: pngs.maxByOrNull { it.size }
                    ?: return
            zip.getInputStream(entry).use { input -> target.outputStream().use { input.copyTo(it) } }
        }
    }

    companion object {
        const val APK = "extension.apk"
        const val META = "meta.json"
        const val ICON = "icon.png"
        const val EXTENSION_FEATURE = "tachiyomi.extension"
        const val METADATA_SOURCE_CLASS = "tachiyomi.extension.class"
        const val METADATA_NSFW = "tachiyomi.extension.nsfw"
        const val LIB_VERSION_MIN = 1.2
        const val LIB_VERSION_MAX = 1.6
    }
}
