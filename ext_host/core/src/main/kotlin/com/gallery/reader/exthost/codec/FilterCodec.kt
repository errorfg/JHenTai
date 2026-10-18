package com.gallery.reader.exthost.codec

import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * Filters go to the app as JSON with their current state; the app sends the
 * edited states back, and they are applied to a fresh `getFilterList()` of the
 * source, matching each filter by position, kind and name.
 */
object FilterCodec {
    fun encode(filters: List<Filter<*>>): JsonArray = JsonArray(filters.map(::encode))

    private fun encode(filter: Filter<*>): JsonObject =
        buildJsonObject {
            put("name", filter.name)
            when (filter) {
                is Filter.Header -> put("type", "header")
                is Filter.Separator -> put("type", "separator")
                is Filter.Select<*> -> {
                    put("type", "select")
                    put("values", buildJsonArray { filter.values.forEach { add(JsonPrimitive(it.toString())) } })
                    put("state", filter.state)
                }
                is Filter.Text -> {
                    put("type", "text")
                    put("state", filter.state)
                }
                is Filter.CheckBox -> {
                    put("type", "checkbox")
                    put("state", filter.state)
                }
                is Filter.TriState -> {
                    put("type", "tristate")
                    put("state", filter.state)
                }
                is Filter.Group<*> -> {
                    put("type", "group")
                    put("state", JsonArray(filter.state.filterIsInstance<Filter<*>>().map(::encode)))
                }
                is Filter.Sort -> {
                    put("type", "sort")
                    put("values", buildJsonArray { filter.values.forEach { add(JsonPrimitive(it)) } })
                    put(
                        "state",
                        filter.state?.let { buildJsonObject { put("index", it.index); put("ascending", it.ascending) } } ?: JsonNull,
                    )
                }
                else -> put("type", "unknown")
            }
        }

    /** Applies the states in [states] (as produced by [encode]) onto [filters]. */
    fun apply(
        filters: FilterList,
        states: JsonArray,
    ): FilterList {
        apply(filters.list, states)
        return filters
    }

    private fun apply(
        filters: List<Filter<*>>,
        states: JsonArray,
    ) {
        filters.forEachIndexed { index, filter ->
            val state =
                (states.getOrNull(index) as? JsonObject)?.takeIf { it.string("name") == filter.name }
                    ?: states.firstOrNull { (it as? JsonObject)?.string("name") == filter.name } as? JsonObject
                    ?: return@forEachIndexed
            val value = state["state"] ?: return@forEachIndexed
            when (filter) {
                is Filter.Select<*> -> value.jsonPrimitive.intOrNull?.takeIf { it in filter.values.indices }?.let { filter.state = it }
                is Filter.Text -> (value as? JsonPrimitive)?.let { filter.state = it.content }
                is Filter.CheckBox -> value.jsonPrimitive.booleanOrNull?.let { filter.state = it }
                is Filter.TriState -> value.jsonPrimitive.intOrNull?.let { filter.state = it }
                is Filter.Group<*> -> (value as? JsonArray)?.let { apply(filter.state.filterIsInstance<Filter<*>>(), it) }
                is Filter.Sort ->
                    filter.state =
                        (value as? JsonObject)?.let { sel ->
                            val i = sel["index"]?.jsonPrimitive?.intOrNull ?: return@let null
                            Filter.Sort.Selection(i, sel["ascending"]?.jsonPrimitive?.booleanOrNull ?: false)
                        }
                else -> Unit
            }
        }
    }
}
