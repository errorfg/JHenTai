package com.gallery.reader.exthost.compat

import android.content.SharedPreferences
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * SharedPreferences kept in one JSON file. Each value is stored with its type
 * (`{"t":"string","v":...}`), so that reading back gives the same kind of value
 * Android would, and a JSON number written as an int is not read as a long.
 */
class JsonSharedPreferences(private val file: File) : SharedPreferences {
    private val lock = Any()
    private val values: MutableMap<String, Any> = load()
    private val listeners = CopyOnWriteArrayList<SharedPreferences.OnSharedPreferenceChangeListener>()

    private fun load(): MutableMap<String, Any> {
        if (!file.exists()) return LinkedHashMap()
        return try {
            val root = Json.parseToJsonElement(file.readText()).jsonObject
            val result = LinkedHashMap<String, Any>()
            for ((key, element) in root) decode(element)?.let { result[key] = it }
            result
        } catch (e: Exception) {
            System.err.println("JsonSharedPreferences: cannot read ${file.path}: $e")
            LinkedHashMap()
        }
    }

    private fun decode(element: JsonElement): Any? {
        val obj = element as? JsonObject ?: return null
        val v = obj["v"] ?: return null
        return when (obj["t"]?.jsonPrimitive?.content) {
            "string" -> v.jsonPrimitive.content
            "set" -> v.jsonArray.map { it.jsonPrimitive.content }.toSet()
            "int" -> v.jsonPrimitive.longOrNull?.toInt()
            "long" -> v.jsonPrimitive.longOrNull
            "float" -> v.jsonPrimitive.doubleOrNull?.toFloat()
            "boolean" -> v.jsonPrimitive.booleanOrNull
            else -> null
        }
    }

    private fun encode(value: Any): JsonElement {
        val (type, v) =
            when (value) {
                is String -> "string" to JsonPrimitive(value)
                is Set<*> -> "set" to JsonArray(value.map { JsonPrimitive(it as String) })
                is Int -> "int" to JsonPrimitive(value)
                is Long -> "long" to JsonPrimitive(value)
                is Float -> "float" to JsonPrimitive(value)
                is Boolean -> "boolean" to JsonPrimitive(value)
                else -> return JsonNull
            }
        return JsonObject(mapOf("t" to JsonPrimitive(type), "v" to v))
    }

    private fun write(snapshot: Map<String, Any>) {
        val text = JsonObject(snapshot.mapValues { encode(it.value) }).toString()
        synchronized(file) {
            file.parentFile?.mkdirs()
            val tmp = File(file.path + ".tmp")
            tmp.writeText(text)
            if (!tmp.renameTo(file)) {
                file.delete()
                tmp.renameTo(file)
            }
        }
    }

    override fun getAll(): Map<String, *> = synchronized(lock) { LinkedHashMap(values) }

    private inline fun <reified T> read(
        key: String,
        default: T,
    ): T = synchronized(lock) { values[key] as? T ?: default }

    override fun getString(
        key: String,
        defValue: String?,
    ): String? = synchronized(lock) { values[key] as? String ?: defValue }

    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(
        key: String,
        defValues: Set<String>?,
    ): Set<String>? = synchronized(lock) { (values[key] as? Set<String>)?.toSet() ?: defValues }

    override fun getInt(
        key: String,
        defValue: Int,
    ): Int = read(key, defValue)

    override fun getLong(
        key: String,
        defValue: Long,
    ): Long = read(key, defValue)

    override fun getFloat(
        key: String,
        defValue: Float,
    ): Float = read(key, defValue)

    override fun getBoolean(
        key: String,
        defValue: Boolean,
    ): Boolean = read(key, defValue)

    override fun contains(key: String): Boolean = synchronized(lock) { key in values }

    override fun edit(): SharedPreferences.Editor = EditorImpl()

    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        listeners.addIfAbsent(listener)
    }

    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        listeners.remove(listener)
    }

    private inner class EditorImpl : SharedPreferences.Editor {
        private val changes = LinkedHashMap<String, Any?>()
        private var clear = false

        private inline fun put(change: () -> Unit): SharedPreferences.Editor {
            change()
            return this
        }

        override fun putString(
            key: String,
            value: String?,
        ): SharedPreferences.Editor = put { changes[key] = value }

        override fun putStringSet(
            key: String,
            values: Set<String>?,
        ): SharedPreferences.Editor = put { changes[key] = values?.toSet() }

        override fun putInt(
            key: String,
            value: Int,
        ): SharedPreferences.Editor = put { changes[key] = value }

        override fun putLong(
            key: String,
            value: Long,
        ): SharedPreferences.Editor = put { changes[key] = value }

        override fun putFloat(
            key: String,
            value: Float,
        ): SharedPreferences.Editor = put { changes[key] = value }

        override fun putBoolean(
            key: String,
            value: Boolean,
        ): SharedPreferences.Editor = put { changes[key] = value }

        override fun remove(key: String): SharedPreferences.Editor = put { changes[key] = null }

        override fun clear(): SharedPreferences.Editor = put { clear = true }

        private fun merge(): Pair<Map<String, Any>, List<String>> =
            synchronized(lock) {
                if (clear) values.clear()
                for ((key, value) in changes) {
                    if (value == null) values.remove(key) else values[key] = value
                }
                LinkedHashMap(values) to changes.keys.toList()
            }

        private fun notify(keys: List<String>) {
            for (key in keys) listeners.forEach { it.onSharedPreferenceChanged(this@JsonSharedPreferences, key) }
        }

        override fun commit(): Boolean {
            val (snapshot, keys) = merge()
            write(snapshot)
            notify(keys)
            return true
        }

        override fun apply() {
            val (snapshot, keys) = merge()
            writer.execute { write(snapshot) }
            notify(keys)
        }
    }

    companion object {
        private val writer =
            Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "preferences-writer").apply { isDaemon = true }
            }
    }
}
