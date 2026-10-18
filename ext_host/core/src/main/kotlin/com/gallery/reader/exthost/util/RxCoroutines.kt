package com.gallery.reader.exthost.util

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runInterruptible
import rx.Observable

/** Waits for the single value of an extension's Rx observable (extensions-lib 1.4 and earlier). */
suspend fun <T> Observable<T>.awaitSingle(): T = runInterruptible(Dispatchers.IO) { toBlocking().single() }
