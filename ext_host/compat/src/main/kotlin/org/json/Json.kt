@file:Suppress("unused")

package org.json

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray as KJsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject as KJsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

// The org.json API that Android ships, for extensions that use it instead of
// kotlinx.serialization. Values are kept as plain Java objects, as on Android.

class JSONException(message: String) : RuntimeException(message)

private fun wrap(element: JsonElement): Any =
    when (element) {
        is JsonNull -> JSONObject.NULL
        is KJsonObject -> JSONObject(element)
        is KJsonArray -> JSONArray(element)
        is JsonPrimitive ->
            when {
                element.isString -> element.content
                element.booleanOrNull != null -> element.booleanOrNull!!
                element.longOrNull != null -> element.longOrNull!!.let { if (it in Int.MIN_VALUE..Int.MAX_VALUE) it.toInt() else it }
                else -> element.doubleOrNull ?: element.content
            }
    }

private fun unwrap(value: Any?): JsonElement =
    when (value) {
        null, JSONObject.NULL -> JsonNull
        is JSONObject -> KJsonObject(value.map.mapValues { unwrap(it.value) })
        is JSONArray -> KJsonArray(value.list.map { unwrap(it) })
        is Boolean -> JsonPrimitive(value)
        is Number -> JsonPrimitive(value)
        is Map<*, *> -> KJsonObject(value.entries.associate { it.key.toString() to unwrap(it.value) })
        is Collection<*> -> KJsonArray(value.map { unwrap(it) })
        else -> JsonPrimitive(value.toString())
    }

private fun parse(text: String): JsonElement =
    try {
        Json.parseToJsonElement(text)
    } catch (e: Exception) {
        throw JSONException(e.message ?: "invalid JSON")
    }

private fun toInt(value: Any?): Int? =
    when (value) {
        is Number -> value.toInt()
        is String -> value.toDoubleOrNull()?.toInt()
        else -> null
    }

private fun toLong(value: Any?): Long? =
    when (value) {
        is Number -> value.toLong()
        is String -> value.toDoubleOrNull()?.toLong()
        else -> null
    }

private fun toDouble(value: Any?): Double? =
    when (value) {
        is Number -> value.toDouble()
        is String -> value.toDoubleOrNull()
        else -> null
    }

private fun toBoolean(value: Any?): Boolean? =
    when (value) {
        is Boolean -> value
        is String -> value.lowercase().toBooleanStrictOrNull()
        else -> null
    }

class JSONObject internal constructor(internal val map: LinkedHashMap<String, Any>) {
    constructor() : this(LinkedHashMap())

    internal constructor(obj: KJsonObject) : this(obj.mapValuesTo(LinkedHashMap()) { wrap(it.value) })

    constructor(json: String) : this((parse(json) as? KJsonObject) ?: throw JSONException("not a JSON object"))

    constructor(copyFrom: Map<*, *>) : this(LinkedHashMap<String, Any>().apply { copyFrom.forEach { (k, v) -> put(k.toString(), v ?: NULL) } })

    fun length(): Int = map.size

    fun has(name: String): Boolean = name in map

    fun isNull(name: String): Boolean = map[name] == null || map[name] == NULL

    fun keys(): Iterator<String> = map.keys.toList().iterator()

    fun names(): JSONArray? = if (map.isEmpty()) null else JSONArray(map.keys.toMutableList<Any>())

    fun opt(name: String): Any? = map[name]

    fun get(name: String): Any = map[name] ?: throw JSONException("No value for $name")

    fun put(
        name: String,
        value: Any?,
    ): JSONObject {
        if (value == null) map.remove(name) else map[name] = value
        return this
    }

    fun put(
        name: String,
        value: Int,
    ): JSONObject = put(name, value as Any)

    fun put(
        name: String,
        value: Long,
    ): JSONObject = put(name, value as Any)

    fun put(
        name: String,
        value: Double,
    ): JSONObject = put(name, value as Any)

    fun put(
        name: String,
        value: Boolean,
    ): JSONObject = put(name, value as Any)

    fun remove(name: String): Any? = map.remove(name)

    fun getString(name: String): String = get(name).let { if (it == NULL) "null" else it.toString() }

    fun optString(name: String): String = optString(name, "")

    fun optString(
        name: String,
        fallback: String,
    ): String = map[name]?.takeIf { it != NULL }?.toString() ?: fallback

    fun getInt(name: String): Int = toInt(get(name)) ?: throw JSONException("$name is not an int")

    fun optInt(name: String): Int = optInt(name, 0)

    fun optInt(
        name: String,
        fallback: Int,
    ): Int = toInt(map[name]) ?: fallback

    fun getLong(name: String): Long = toLong(get(name)) ?: throw JSONException("$name is not a long")

    fun optLong(name: String): Long = optLong(name, 0L)

    fun optLong(
        name: String,
        fallback: Long,
    ): Long = toLong(map[name]) ?: fallback

    fun getDouble(name: String): Double = toDouble(get(name)) ?: throw JSONException("$name is not a number")

    fun optDouble(name: String): Double = optDouble(name, Double.NaN)

    fun optDouble(
        name: String,
        fallback: Double,
    ): Double = toDouble(map[name]) ?: fallback

    fun getBoolean(name: String): Boolean = toBoolean(get(name)) ?: throw JSONException("$name is not a boolean")

    fun optBoolean(name: String): Boolean = optBoolean(name, false)

    fun optBoolean(
        name: String,
        fallback: Boolean,
    ): Boolean = toBoolean(map[name]) ?: fallback

    fun getJSONObject(name: String): JSONObject = get(name) as? JSONObject ?: throw JSONException("$name is not a JSONObject")

    fun optJSONObject(name: String): JSONObject? = map[name] as? JSONObject

    fun getJSONArray(name: String): JSONArray = get(name) as? JSONArray ?: throw JSONException("$name is not a JSONArray")

    fun optJSONArray(name: String): JSONArray? = map[name] as? JSONArray

    override fun toString(): String = unwrap(this).toString()

    fun toString(indentSpaces: Int): String = toString()

    companion object {
        @JvmField
        val NULL: Any =
            object {
                override fun equals(other: Any?): Boolean = other == null || other === this

                override fun hashCode(): Int = 0

                override fun toString(): String = "null"
            }

        @JvmStatic
        fun quote(data: String?): String = JsonPrimitive(data ?: "").toString()
    }
}

class JSONArray internal constructor(internal val list: MutableList<Any>) {
    constructor() : this(mutableListOf())

    internal constructor(array: KJsonArray) : this(array.mapTo(mutableListOf()) { wrap(it) })

    constructor(json: String) : this((parse(json) as? KJsonArray) ?: throw JSONException("not a JSON array"))

    constructor(copyFrom: Collection<*>) : this(copyFrom.mapTo(mutableListOf()) { it ?: JSONObject.NULL })

    fun length(): Int = list.size

    fun opt(index: Int): Any? = list.getOrNull(index)

    fun get(index: Int): Any = list.getOrNull(index) ?: throw JSONException("Index $index out of range")

    fun isNull(index: Int): Boolean = opt(index) == null || opt(index) == JSONObject.NULL

    fun put(value: Any?): JSONArray {
        list.add(value ?: JSONObject.NULL)
        return this
    }

    fun put(value: Int): JSONArray = put(value as Any)

    fun put(value: Long): JSONArray = put(value as Any)

    fun put(value: Double): JSONArray = put(value as Any)

    fun put(value: Boolean): JSONArray = put(value as Any)

    fun put(
        index: Int,
        value: Any?,
    ): JSONArray {
        while (list.size <= index) list.add(JSONObject.NULL)
        list[index] = value ?: JSONObject.NULL
        return this
    }

    fun remove(index: Int): Any? = if (index in list.indices) list.removeAt(index) else null

    fun getString(index: Int): String = get(index).toString()

    fun optString(index: Int): String = optString(index, "")

    fun optString(
        index: Int,
        fallback: String,
    ): String = opt(index)?.takeIf { it != JSONObject.NULL }?.toString() ?: fallback

    fun getInt(index: Int): Int = toInt(get(index)) ?: throw JSONException("$index is not an int")

    fun optInt(index: Int): Int = toInt(opt(index)) ?: 0

    fun optInt(
        index: Int,
        fallback: Int,
    ): Int = toInt(opt(index)) ?: fallback

    fun getLong(index: Int): Long = toLong(get(index)) ?: throw JSONException("$index is not a long")

    fun optLong(index: Int): Long = toLong(opt(index)) ?: 0L

    fun getDouble(index: Int): Double = toDouble(get(index)) ?: throw JSONException("$index is not a number")

    fun getBoolean(index: Int): Boolean = toBoolean(get(index)) ?: throw JSONException("$index is not a boolean")

    fun optBoolean(index: Int): Boolean = toBoolean(opt(index)) ?: false

    fun getJSONObject(index: Int): JSONObject = get(index) as? JSONObject ?: throw JSONException("$index is not a JSONObject")

    fun optJSONObject(index: Int): JSONObject? = opt(index) as? JSONObject

    fun getJSONArray(index: Int): JSONArray = get(index) as? JSONArray ?: throw JSONException("$index is not a JSONArray")

    fun optJSONArray(index: Int): JSONArray? = opt(index) as? JSONArray

    fun join(separator: String): String = list.joinToString(separator) { unwrap(it).toString() }

    override fun toString(): String = unwrap(this).toString()

    fun toString(indentSpaces: Int): String = toString()
}
