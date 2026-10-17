package uy.kohesive.injekt

import uy.kohesive.injekt.api.get

inline fun <reified T : Any> injectLazy(): Lazy<T> = lazy { Injekt.get<T>() }

inline fun <reified T : Any> injectValue(): Lazy<T> = lazyOf(Injekt.get<T>())
