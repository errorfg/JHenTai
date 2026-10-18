# Extensions are loaded at run time and call into the host and the libraries
# they were compiled against by name: nothing of these may be removed or
# renamed.
-keep class eu.kanade.tachiyomi.** { *; }
-keep class uy.kohesive.injekt.** { *; }
-keep class com.gallery.reader.exthost.** { *; }
-keep class kotlin.** { *; }
-keep class kotlinx.coroutines.** { *; }
-keep class kotlinx.serialization.** { *; }
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keep class org.jsoup.** { *; }
-keep class rx.** { *; }
-keep class androidx.preference.** { *; }
-dontwarn org.jsoup.**
-dontwarn okhttp3.**
-dontwarn rx.**
