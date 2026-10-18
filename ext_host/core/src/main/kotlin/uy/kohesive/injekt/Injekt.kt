package uy.kohesive.injekt

import uy.kohesive.injekt.api.InjektScope

// The dependency lookup Tachiyomi extensions use (`injectLazy<Json>()` and the
// like, inlined into the extension). This is the part of the Injekt library's
// API that extensions link against, implemented over a type-keyed registry.

@Volatile
var Injekt: InjektScope = InjektScope()
