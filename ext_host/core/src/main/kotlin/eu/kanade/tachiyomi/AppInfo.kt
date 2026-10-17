package eu.kanade.tachiyomi

/**
 * Host information extensions may ask for.
 *
 * @since extension-lib 1.3
 */
@Suppress("UNUSED")
object AppInfo {
    fun getVersionCode(): Int = 1

    fun getVersionName(): String = "1.0"

    /** @since extension-lib 1.5 */
    fun getSupportedImageMimeTypes(): List<String> = listOf("image/jpeg", "image/png", "image/gif", "image/webp", "image/avif", "image/heif", "image/jxl")
}
