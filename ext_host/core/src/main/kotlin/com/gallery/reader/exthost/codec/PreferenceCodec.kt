package com.gallery.reader.exthost.codec

import androidx.preference.DialogPreference
import androidx.preference.EditTextPreference
import androidx.preference.ListPreference
import androidx.preference.MultiSelectListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceGroup
import androidx.preference.PreferenceScreen
import androidx.preference.TwoStatePreference
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * The settings an extension declares in setupPreferenceScreen, as a flat JSON
 * list for the app's settings page. Categories become `category` rows
 * followed by their preferences.
 */
object PreferenceCodec {
    fun encode(screen: PreferenceScreen): JsonArray =
        buildJsonArray {
            fun walk(group: PreferenceGroup) {
                for (i in 0 until group.preferenceCount) {
                    val preference = group.getPreference(i)
                    if (preference is PreferenceGroup) {
                        add(base(preference, "category"))
                        walk(preference)
                    } else {
                        add(encode(preference))
                    }
                }
            }
            walk(screen)
        }

    private fun base(
        preference: Preference,
        type: String,
        extra: MutableMap<String, JsonElement>.() -> Unit = {},
    ): JsonObject {
        val fields = linkedMapOf<String, JsonElement>()
        fields["type"] = JsonPrimitive(type)
        fields["key"] = JsonPrimitive(preference.key)
        fields["title"] = JsonPrimitive(preference.title?.toString())
        fields["summary"] = JsonPrimitive(runCatching { preference.summary?.toString() }.getOrNull())
        fields["visible"] = JsonPrimitive(preference.isVisible)
        fields["enabled"] = JsonPrimitive(preference.isEnabled)
        if (preference is DialogPreference) {
            fields["dialogTitle"] = JsonPrimitive(preference.dialogTitle?.toString())
            fields["dialogMessage"] = JsonPrimitive(preference.dialogMessage?.toString())
        }
        fields.extra()
        return JsonObject(fields)
    }

    private fun strings(values: Array<CharSequence>?): JsonArray = JsonArray(values.orEmpty().map { JsonPrimitive(it.toString()) })

    private fun encode(preference: Preference): JsonObject =
        when (preference) {
            is ListPreference ->
                base(preference, "list") {
                    put("entries", strings(preference.entries))
                    put("entryValues", strings(preference.entryValues))
                    put("value", JsonPrimitive(preference.value))
                }
            is MultiSelectListPreference ->
                base(preference, "multiSelect") {
                    put("entries", strings(preference.entries))
                    put("entryValues", strings(preference.entryValues))
                    put("value", JsonArray(preference.values.map { JsonPrimitive(it) }))
                }
            is EditTextPreference -> base(preference, "text") { put("value", JsonPrimitive(preference.text)) }
            is TwoStatePreference -> base(preference, "switch") { put("value", JsonPrimitive(preference.isChecked)) }
            else -> base(preference, "info")
        }

    /**
     * Sets [key] to [value] the way the Android settings screen does: the
     * extension's change listener is asked first and may refuse the value.
     * Returns whether the value was stored.
     */
    fun set(
        screen: PreferenceScreen,
        key: String,
        value: JsonElement,
    ): Boolean {
        val preference = screen.findPreference<Preference>(key) ?: throw IllegalArgumentException("no preference $key")
        return when (preference) {
            is ListPreference -> {
                val v = value.jsonPrimitive.content
                preference.callChangeListener(v).also { if (it) preference.value = v }
            }
            is MultiSelectListPreference -> {
                val v = (value as JsonArray).map { it.jsonPrimitive.content }.toSet()
                preference.callChangeListener(v).also { if (it) preference.values = v }
            }
            is EditTextPreference -> {
                val v = value.jsonPrimitive.content
                preference.callChangeListener(v).also { if (it) preference.text = v }
            }
            is TwoStatePreference -> {
                val v = value.jsonPrimitive.booleanOrNull ?: throw IllegalArgumentException("$key takes true or false")
                preference.callChangeListener(v).also { if (it) preference.isChecked = v }
            }
            else -> throw IllegalArgumentException("$key cannot be set")
        }
    }
}
