package com.gallery.reader.exthost.extension

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * What the host needs from an APK's binary AndroidManifest.xml: the package,
 * its version, the application label, declared features and the
 * application's meta-data (where Tachiyomi extensions name their source class).
 */
class ApkManifest(
    val packageName: String,
    val versionCode: Long,
    val versionName: String,
    val label: String?,
    val features: List<String>,
    val metaData: Map<String, String>,
) {
    companion object {
        private const val RES_STRING_POOL_TYPE = 0x0001
        private const val RES_XML_TYPE = 0x0003
        private const val RES_XML_RESOURCE_MAP_TYPE = 0x0180
        private const val RES_XML_START_ELEMENT_TYPE = 0x0102
        private const val RES_XML_END_ELEMENT_TYPE = 0x0103
        private const val UTF8_FLAG = 0x100

        private const val TYPE_REFERENCE = 0x01
        private const val TYPE_STRING = 0x03
        private const val TYPE_FLOAT = 0x04
        private const val TYPE_INT_DEC = 0x10
        private const val TYPE_INT_HEX = 0x11
        private const val TYPE_INT_BOOLEAN = 0x12

        // Attribute names by resource id, for manifests whose string pool leaves them empty.
        private val ATTRIBUTE_NAMES =
            mapOf(
                0x01010003 to "name",
                0x01010024 to "value",
                0x01010001 to "label",
                0x0101021b to "versionCode",
                0x0101021c to "versionName",
            )

        fun parse(bytes: ByteArray): ApkManifest {
            val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            require(buf.getShort(0).toInt() and 0xffff == RES_XML_TYPE) { "not a binary XML file" }
            var strings: List<String> = emptyList()
            var resourceIds = IntArray(0)

            var packageName = ""
            var versionCode = 0L
            var versionName = ""
            var label: String? = null
            val features = mutableListOf<String>()
            val metaData = linkedMapOf<String, String>()
            val path = ArrayDeque<String>()

            var offset = buf.getShort(2).toInt() and 0xffff
            while (offset + 8 <= bytes.size) {
                val type = buf.getShort(offset).toInt() and 0xffff
                val headerSize = buf.getShort(offset + 2).toInt() and 0xffff
                val size = buf.getInt(offset + 4)
                if (size <= 0) break
                when (type) {
                    RES_STRING_POOL_TYPE -> strings = readStringPool(buf, offset)
                    RES_XML_RESOURCE_MAP_TYPE -> resourceIds = IntArray((size - headerSize) / 4) { buf.getInt(offset + headerSize + it * 4) }
                    RES_XML_START_ELEMENT_TYPE -> {
                        val name = strings.getOrElse(buf.getInt(offset + 20)) { "" }
                        val attributeStart = buf.getShort(offset + 24).toInt() and 0xffff
                        val attributeSize = buf.getShort(offset + 26).toInt() and 0xffff
                        val attributeCount = buf.getShort(offset + 28).toInt() and 0xffff
                        val attributes = mutableMapOf<String, String>()
                        for (i in 0 until attributeCount) {
                            val at = offset + headerSize + attributeStart + i * attributeSize
                            val nameIndex = buf.getInt(at + 4)
                            val attributeName =
                                strings.getOrNull(nameIndex)?.takeIf { it.isNotEmpty() }
                                    ?: resourceIds.getOrNull(nameIndex)?.let { ATTRIBUTE_NAMES[it] }
                                    ?: continue
                            val raw = buf.getInt(at + 8)
                            val dataType = buf.get(at + 15).toInt() and 0xff
                            val data = buf.getInt(at + 16)
                            attributes[attributeName] =
                                when {
                                    raw != -1 -> strings.getOrElse(raw) { "" }
                                    dataType == TYPE_STRING -> strings.getOrElse(data) { "" }
                                    dataType == TYPE_INT_BOOLEAN -> (data != 0).toString()
                                    dataType == TYPE_INT_DEC -> data.toString()
                                    dataType == TYPE_INT_HEX -> data.toString()
                                    dataType == TYPE_FLOAT -> java.lang.Float.intBitsToFloat(data).toString()
                                    dataType == TYPE_REFERENCE -> "@0x%08x".format(data)
                                    else -> data.toString()
                                }
                        }
                        path.addLast(name)
                        when (path.joinToString("/")) {
                            "manifest" -> {
                                packageName = attributes["package"].orEmpty()
                                versionCode = attributes["versionCode"]?.toLongOrNull() ?: 0
                                versionName = attributes["versionName"].orEmpty()
                            }
                            "manifest/application" -> label = attributes["label"]?.takeUnless { it.startsWith("@") }
                            "manifest/uses-feature" -> attributes["name"]?.let(features::add)
                            "manifest/application/meta-data" -> {
                                val key = attributes["name"]
                                val value = attributes["value"]
                                if (key != null && value != null) metaData[key] = value
                            }
                        }
                    }
                    RES_XML_END_ELEMENT_TYPE -> path.removeLastOrNull()
                }
                offset += size
            }
            return ApkManifest(packageName, versionCode, versionName, label, features, metaData)
        }

        private fun readStringPool(
            buf: ByteBuffer,
            chunk: Int,
        ): List<String> {
            val count = buf.getInt(chunk + 8)
            val flags = buf.getInt(chunk + 16)
            val stringsStart = buf.getInt(chunk + 20)
            val headerSize = buf.getShort(chunk + 2).toInt() and 0xffff
            val utf8 = flags and UTF8_FLAG != 0
            return List(count) { i ->
                var at = chunk + stringsStart + buf.getInt(chunk + headerSize + i * 4)
                if (utf8) {
                    // UTF-16 length, then UTF-8 length; each one or two bytes.
                    at += if (buf.get(at).toInt() and 0x80 != 0) 2 else 1
                    var length = buf.get(at).toInt() and 0xff
                    if (length and 0x80 != 0) {
                        length = ((length and 0x7f) shl 8) or (buf.get(at + 1).toInt() and 0xff)
                        at += 2
                    } else {
                        at += 1
                    }
                    val bytes = ByteArray(length) { buf.get(at + it) }
                    String(bytes, Charsets.UTF_8)
                } else {
                    var length = buf.getShort(at).toInt() and 0xffff
                    if (length and 0x8000 != 0) {
                        length = ((length and 0x7fff) shl 16) or (buf.getShort(at + 2).toInt() and 0xffff)
                        at += 4
                    } else {
                        at += 2
                    }
                    String(CharArray(length) { buf.getChar(at + it * 2) })
                }
            }
        }
    }
}
