// Runs the Tachiyomi extension host (ext_host/) on a JVM inside the app's
// process, as ext_host/flutter/ios/Classes/ExtHostJVM.m does on iOS.
//
// The VM is OpenJDK's Zero interpreter with java.base's native libraries,
// linked into libjdkhost.so, which this library loads by name. Neither that
// library nor the JDK's headers are in the repository: the build copies them
// in (jdk/include, see CMakeLists.txt). Without them this library still
// builds, and reports that the build has no extension host.
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <hilog/log.h>
#include <napi/native_api.h>

#ifdef EXTHOST_HAS_JDK
#include "jni.h"
#endif

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "ExtHost"
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

#define VM_LIBRARY "libjdkhost.so"
#define MESSAGE_SIZE 1024

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    // input (start only)
    char *java_home;
    char *jar;
    char *tmp_dir;
    char *user_home;
    char *config;
    int restart;
    // output
    int port;
    char message[MESSAGE_SIZE];
    // napi
    napi_async_work work;
    napi_deferred deferred;
} Call;

#ifdef EXTHOST_HAS_JDK

static JavaVM *g_vm = NULL;
static jclass g_embedded = NULL;

static char *option(const char *prefix, const char *value) {
    size_t n = strlen(prefix) + strlen(value) + 1;
    char *s = malloc(n);
    snprintf(s, n, "%s%s", prefix, value);
    return s;
}

/// The exception pending in `env`, as text, cleared.
static void take_exception(JNIEnv *env, char *out) {
    jthrowable exception = (*env)->ExceptionOccurred(env);
    (*env)->ExceptionClear(env);
    snprintf(out, MESSAGE_SIZE, "unknown error");
    if (exception == NULL) {
        return;
    }
    jclass object_class = (*env)->FindClass(env, "java/lang/Object");
    jmethodID to_string = (*env)->GetMethodID(env, object_class, "toString", "()Ljava/lang/String;");
    jstring text = (jstring)(*env)->CallObjectMethod(env, exception, to_string);
    if ((*env)->ExceptionCheck(env) || text == NULL) {
        (*env)->ExceptionClear(env);
        return;
    }
    const char *chars = (*env)->GetStringUTFChars(env, text, NULL);
    snprintf(out, MESSAGE_SIZE, "%s", chars);
    (*env)->ReleaseStringUTFChars(env, text, chars);
}

static int create_vm(Call *call, JNIEnv **env) {
    // HotSpot ends the process when it cannot find its runtime image, so
    // the files are checked first.
    char modules[4096];
    snprintf(modules, sizeof modules, "%s/lib/modules", call->java_home);
    if (access(modules, R_OK) != 0 || access(call->jar, R_OK) != 0) {
        snprintf(call->message, MESSAGE_SIZE, "This build does not include the extension host");
        return 0;
    }
    void *library = dlopen(VM_LIBRARY, RTLD_NOW | RTLD_GLOBAL);
    if (library == NULL) {
        snprintf(call->message, MESSAGE_SIZE, "This build does not include the extension host (%s)", dlerror());
        return 0;
    }
    typedef jint (*create_fn)(JavaVM **, void **, void *);
    create_fn create = (create_fn)dlsym(library, "JNI_CreateJavaVM");
    if (create == NULL) {
        snprintf(call->message, MESSAGE_SIZE, "JNI_CreateJavaVM is missing from %s", VM_LIBRARY);
        return 0;
    }
    // The same options as on iOS, and java.home: the VM is not next to its
    // runtime image.
    char *strings[] = {
        option("-Djava.home=", call->java_home),
        option("-Djava.class.path=", call->jar),
        option("-Djava.io.tmpdir=", call->tmp_dir),
        option("-Duser.home=", call->user_home),
        strdup("-Dfile.encoding=UTF-8"),
        strdup("-Xmx384m"),
        strdup("-Xrs"),
        strdup("-Xshare:off"),
        strdup("-XX:-UsePerfData"),
        strdup("-XX:+DisableAttachMechanism"),
        strdup("-XX:+UnlockDiagnosticVMOptions"),
        // Extension classes refer to Android classes the host does not have.
        strdup("-XX:-BytecodeVerificationRemote"),
    };
    int count = (int)(sizeof strings / sizeof strings[0]);
    JavaVMOption options[sizeof strings / sizeof strings[0]];
    for (int i = 0; i < count; i++) {
        options[i].optionString = strings[i];
        options[i].extraInfo = NULL;
    }
    JavaVMInitArgs args;
    args.version = JNI_VERSION_10;
    args.nOptions = count;
    args.options = options;
    args.ignoreUnrecognized = JNI_FALSE;
    LOGI("creating the JVM, java.home %{public}s", call->java_home);
    jint rc = create(&g_vm, (void **)env, &args);
    if (rc != JNI_OK) {
        g_vm = NULL;
        snprintf(call->message, MESSAGE_SIZE, "JNI_CreateJavaVM failed: %d", (int)rc);
        return 0;
    }
    LOGI("JVM created");
    jclass embedded = (*(*env))->FindClass(*env, "com/gallery/reader/exthost/jvm/Embedded");
    if (embedded == NULL) {
        take_exception(*env, call->message);
        return 0;
    }
    g_embedded = (jclass)(*(*env))->NewGlobalRef(*env, embedded);
    return 1;
}

/// Runs on a thread of its own: the VM needs more stack than a worker has.
static void *run(void *data) {
    Call *call = data;
    call->port = -1;
    pthread_mutex_lock(&g_lock);
    JNIEnv *env = NULL;
    if (g_vm == NULL) {
        if (call->restart || !create_vm(call, &env)) {
            pthread_mutex_unlock(&g_lock);
            return NULL;
        }
    } else if ((*g_vm)->AttachCurrentThread(g_vm, (void **)&env, NULL) != JNI_OK) {
        snprintf(call->message, MESSAGE_SIZE, "cannot attach to the JVM");
        pthread_mutex_unlock(&g_lock);
        return NULL;
    }
    if (call->restart) {
        jmethodID restart = (*env)->GetStaticMethodID(env, g_embedded, "restartServer", "()I");
        call->port = (*env)->CallStaticIntMethod(env, g_embedded, restart);
    } else {
        jmethodID start = (*env)->GetStaticMethodID(env, g_embedded, "start", "(Ljava/lang/String;)I");
        jstring argument = (*env)->NewStringUTF(env, call->config);
        call->port = (*env)->CallStaticIntMethod(env, g_embedded, start, argument);
        (*env)->DeleteLocalRef(env, argument);
    }
    if ((*env)->ExceptionCheck(env)) {
        take_exception(env, call->message);
        call->port = -1;
    }
    (*g_vm)->DetachCurrentThread(g_vm);
    pthread_mutex_unlock(&g_lock);
    return NULL;
}

#else

static void *run(void *data) {
    Call *call = data;
    call->port = -1;
    snprintf(call->message, MESSAGE_SIZE, "This build does not include the extension host");
    return NULL;
}

#endif

static void execute(napi_env env, void *data) {
    (void)env;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8u << 20);
    pthread_t thread;
    if (pthread_create(&thread, &attr, run, data) != 0) {
        Call *call = data;
        call->port = -1;
        snprintf(call->message, MESSAGE_SIZE, "cannot create a thread for the JVM");
        return;
    }
    pthread_join(thread, NULL);
}

static void complete(napi_env env, napi_status status, void *data) {
    (void)status;
    Call *call = data;
    if (call->port > 0 || call->restart) {
        napi_value port;
        napi_create_int32(env, call->port, &port);
        napi_resolve_deferred(env, call->deferred, port);
    } else {
        napi_value message, error;
        napi_create_string_utf8(env, call->message[0] ? call->message : "the host did not start", NAPI_AUTO_LENGTH,
                                &message);
        napi_create_error(env, NULL, message, &error);
        napi_reject_deferred(env, call->deferred, error);
    }
    napi_delete_async_work(env, call->work);
    free(call->java_home);
    free(call->jar);
    free(call->tmp_dir);
    free(call->user_home);
    free(call->config);
    free(call);
}

static char *string_argument(napi_env env, napi_value value) {
    size_t length = 0;
    napi_get_value_string_utf8(env, value, NULL, 0, &length);
    char *text = malloc(length + 1);
    napi_get_value_string_utf8(env, value, text, length + 1, &length);
    return text;
}

static napi_value queue(napi_env env, Call *call, const char *name) {
    napi_value promise, resource;
    napi_create_promise(env, &call->deferred, &promise);
    napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &resource);
    napi_create_async_work(env, NULL, resource, execute, complete, call, &call->work);
    napi_queue_async_work(env, call->work);
    return promise;
}

static napi_value start(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value argv[5];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (argc < 5) {
        napi_throw_error(env, NULL, "start(javaHome, jar, tmpDir, userHome, config)");
        return NULL;
    }
    Call *call = calloc(1, sizeof *call);
    call->java_home = string_argument(env, argv[0]);
    call->jar = string_argument(env, argv[1]);
    call->tmp_dir = string_argument(env, argv[2]);
    call->user_home = string_argument(env, argv[3]);
    call->config = string_argument(env, argv[4]);
    return queue(env, call, "exthost.start");
}

static napi_value restart_server(napi_env env, napi_callback_info info) {
    (void)info;
    Call *call = calloc(1, sizeof *call);
    call->restart = 1;
    return queue(env, call, "exthost.restartServer");
}

static napi_value init(napi_env env, napi_value exports) {
    napi_property_descriptor properties[] = {
        {"start", NULL, start, NULL, NULL, NULL, napi_default, NULL},
        {"restartServer", NULL, restart_server, NULL, NULL, NULL, napi_default, NULL},
    };
    napi_define_properties(env, exports, sizeof properties / sizeof properties[0], properties);
    return exports;
}

static napi_module exthost_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = NULL,
    .nm_register_func = init,
    .nm_modname = "exthost",
    .nm_priv = NULL,
    .reserved = {0},
};

__attribute__((constructor)) static void register_exthost(void) { napi_module_register(&exthost_module); }
