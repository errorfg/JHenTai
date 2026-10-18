package com.gallery.reader.exthost.codec

import android.content.SharedPreferences
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * Everything a source keeps in its SharedPreferences, settings and its own
 * state alike, as typed JSON (`{"key": {"t": "string", "v": ...}}`), so the
 * app can carry it to another device.
 */
object PreferenceStore {
    fun read(preferences: SharedPreferences): JsonObject =
        JsonObject(
            preferences.all.mapNotNull { (key, value) ->
                val typed: Pair<String, JsonElement> =
                    when (value) {
                        is String -> "string" to JsonPrimitive(value)
                        is Boolean -> "boolean" to JsonPrimitive(value)
                        is Int -> "int" to JsonPrimitive(value)
                        is Long -> "long" to JsonPrimitive(value)
                        is Float -> "float" to JsonPrimitive(value)
                        is Set<*> -> "set" to JsonArray(value.map { JsonPrimitive(it.toString()) })
                        else -> return@mapNotNull null
                    }
                key to JsonObject(mapOf("t" to JsonPrimitive(typed.first), "v" to typed.second))
            }.toMap(),
        )

    /** Replaces everything in [preferences] with [values]. */
    fun write(
        preferences: SharedPreferences,
        values: JsonObject,
    ) {
        val editor = preferences.edit().clear()
        for ((key, element) in values) {
            val typed = element as? JsonObject ?: continue
            val v = typed["v"] ?: continue
            when (typed["t"]?.jsonPrimitive?.content) {
                "string" -> editor.putString(key, v.jsonPrimitive.content)
                "boolean" -> v.jsonPrimitive.booleanOrNull?.let { editor.putBoolean(key, it) }
                "int" -> v.jsonPrimitive.longOrNull?.let { editor.putInt(key, it.toInt()) }
                "long" -> v.jsonPrimitive.longOrNull?.let { editor.putLong(key, it) }
                "float" -> v.jsonPrimitive.doubleOrNull?.let { editor.putFloat(key, it.toFloat()) }
                "set" -> editor.putStringSet(key, v.jsonArray.map { it.jsonPrimitive.content }.toSet())
            }
        }
        editor.commit()
    }
}
