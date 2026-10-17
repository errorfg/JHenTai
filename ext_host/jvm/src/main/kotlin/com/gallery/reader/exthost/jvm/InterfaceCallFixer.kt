package com.gallery.reader.exthost.jvm

import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/**
 * Dex does not record whether a called method belongs to an interface, and
 * dex2jar writes `invokespecial` and `invokestatic` calls with a class
 * method reference. The JVM rejects that for interface methods (an
 * extension calling an interface's default or static method), so those calls
 * are marked as interface calls here. Whether a class is an interface is read
 * from the jar itself, then from the host's classes.
 */
object InterfaceCallFixer {
    fun fix(
        jar: File,
        host: ClassLoader,
    ): Int {
        val entries = ZipFile(jar).use { zip -> zip.entries().asSequence().map { it.name to zip.getInputStream(it).readBytes() }.toList() }
        val interfaces = HashSet<String>()
        for ((name, bytes) in entries) {
            if (name.endsWith(".class") && ClassReader(bytes).access and Opcodes.ACC_INTERFACE != 0) interfaces += name.removeSuffix(".class")
        }
        val known = HashMap<String, Boolean>()

        fun isInterface(owner: String): Boolean =
            owner in interfaces ||
                known.getOrPut(owner) {
                    try {
                        Class.forName(owner.replace('/', '.'), false, host).isInterface
                    } catch (_: Throwable) {
                        false
                    }
                }

        var fixed = 0
        val tmp = File(jar.path + ".fix")
        ZipOutputStream(tmp.outputStream().buffered()).use { out ->
            for ((name, bytes) in entries) {
                var data = bytes
                if (name.endsWith(".class")) {
                    val reader = ClassReader(bytes)
                    val writer = ClassWriter(reader, 0)
                    var changed = false
                    reader.accept(
                        object : ClassVisitor(Opcodes.ASM9, writer) {
                            override fun visitMethod(
                                access: Int,
                                name: String?,
                                descriptor: String?,
                                signature: String?,
                                exceptions: Array<out String>?,
                            ): MethodVisitor =
                                object : MethodVisitor(Opcodes.ASM9, super.visitMethod(access, name, descriptor, signature, exceptions)) {
                                    override fun visitMethodInsn(
                                        opcode: Int,
                                        owner: String,
                                        name: String,
                                        descriptor: String,
                                        isInterface: Boolean,
                                    ) {
                                        val itf = isInterface || ((opcode == Opcodes.INVOKESPECIAL || opcode == Opcodes.INVOKESTATIC) && isInterface(owner))
                                        if (itf != isInterface) changed = true
                                        super.visitMethodInsn(opcode, owner, name, descriptor, itf)
                                    }
                                }
                        },
                        0,
                    )
                    if (changed) {
                        data = writer.toByteArray()
                        fixed++
                    }
                }
                out.putNextEntry(ZipEntry(name))
                out.write(data)
                out.closeEntry()
            }
        }
        check(tmp.renameTo(jar) || (jar.delete() && tmp.renameTo(jar))) { "cannot write ${jar.path}" }
        return fixed
    }
}
