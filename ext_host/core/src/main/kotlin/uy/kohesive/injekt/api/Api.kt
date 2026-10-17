package uy.kohesive.injekt.api

import uy.kohesive.injekt.Injekt
import java.lang.reflect.ParameterizedType
import java.lang.reflect.Type
import java.util.concurrent.ConcurrentHashMap

interface TypeReference<T> {
    val type: Type
}

/** Captures `T` from the anonymous subclass an inlined `fullType<T>()` creates. */
abstract class FullTypeReference<T> : TypeReference<T> {
    override val type: Type =
        javaClass.genericSuperclass.let { superclass ->
            check(superclass is ParameterizedType) { "FullTypeReference must be created with a type argument" }
            superclass.actualTypeArguments[0]
        }
}

inline fun <reified T> fullType(): FullTypeReference<T> = object : FullTypeReference<T>() {}

interface InjektFactory {
    fun <R : Any> getInstance(forType: Type): R

    fun <R : Any> getInstanceOrElse(
        forType: Type,
        default: R,
    ): R

    fun <R : Any> getInstanceOrNull(forType: Type): R?
}

open class InjektScope : InjektFactory {
    private val instances = ConcurrentHashMap<Type, () -> Any>()

    fun <T : Any> addSingleton(
        forType: Type,
        instance: T,
    ) {
        instances[forType] = { instance }
    }

    fun <T : Any> addSingletonFactory(
        forType: Type,
        factory: () -> T,
    ) {
        val value by lazy(factory)
        instances[forType] = { value }
    }

    private fun find(forType: Type): (() -> Any)? = instances[forType] ?: (forType as? ParameterizedType)?.rawType?.let { instances[it] }

    @Suppress("UNCHECKED_CAST")
    override fun <R : Any> getInstance(forType: Type): R = (find(forType) ?: throw IllegalStateException("No instance registered for $forType")).invoke() as R

    @Suppress("UNCHECKED_CAST")
    override fun <R : Any> getInstanceOrElse(
        forType: Type,
        default: R,
    ): R = find(forType)?.invoke() as R? ?: default

    @Suppress("UNCHECKED_CAST")
    override fun <R : Any> getInstanceOrNull(forType: Type): R? = find(forType)?.invoke() as R?
}

inline fun <reified T : Any> InjektFactory.get(): T = getInstance(fullType<T>().type)

inline fun <reified T : Any> InjektFactory.getOrNull(): T? = getInstanceOrNull(fullType<T>().type)

inline fun <reified T : Any> InjektScope.addSingleton(instance: T) = addSingleton(fullType<T>().type, instance)
