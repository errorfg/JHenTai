package com.gallery.reader.exthost.jvm

import com.googlecode.d2j.Method
import com.googlecode.d2j.dex.BaseDexExceptionHandler
import com.googlecode.d2j.dex.Dex2jar
import com.googlecode.d2j.node.DexMethodNode
import com.googlecode.d2j.reader.MultiDexFileReader
import org.objectweb.asm.MethodVisitor
import java.io.File

/**
 * Converts an APK's dex code to a jar of JVM classes, once, when the
 * extension is installed. A method dex2jar cannot translate is replaced by
 * one that throws, so the rest of the extension still loads.
 */
object DexConverter {
    class Result(
        val classes: Int,
        val failedMethods: List<String>,
        val fixedClasses: Int,
        val millis: Long,
    )

    fun convert(
        apk: File,
        jar: File,
    ): Result {
        val started = System.currentTimeMillis()
        val reader = MultiDexFileReader.open(apk.readBytes())
        val failed = mutableListOf<String>()
        val handler =
            object : BaseDexExceptionHandler() {
                override fun handleMethodTranslateException(
                    method: Method,
                    methodNode: DexMethodNode,
                    mv: MethodVisitor,
                    e: Exception,
                ) {
                    synchronized(failed) { failed += "$method: $e" }
                    super.handleMethodTranslateException(method, methodNode, mv, e)
                }
            }
        val tmp = File(jar.path + ".tmp").apply { delete() }
        Dex2jar
            .from(reader)
            .withExceptionHandler(handler)
            .reUseReg(false)
            .topoLogicalSort()
            .skipDebug(true)
            .optimizeSynchronized(false)
            .printIR(false)
            .noCode(false)
            .skipExceptions(false)
            .dontSanitizeNames(true)
            .computeFrames(true)
            .to(tmp.toPath())
        val fixed = InterfaceCallFixer.fix(tmp, DexConverter::class.java.classLoader)
        if (!tmp.renameTo(jar)) {
            jar.delete()
            check(tmp.renameTo(jar)) { "cannot write ${jar.path}" }
        }
        return Result(reader.classNames.size, failed, fixed, System.currentTimeMillis() - started)
    }
}
