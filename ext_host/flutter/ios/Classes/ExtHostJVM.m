#import "ExtHostJVM.h"

#include <jni.h>

// ExtHostNet.m
extern jobjectArray ExtHostNetCall(JNIEnv *env, jclass cls, jbyteArray meta, jbyteArray body);

static JavaVM *gJvm = NULL;
static jclass gEmbedded = NULL;

@implementation ExtHostJVM

+ (NSError *)error:(NSString *)message {
    return [NSError errorWithDomain:@"ExtHost" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// The exception pending in `env`, as text, cleared.
+ (NSString *)takeException:(JNIEnv *)env {
    jthrowable exception = (*env)->ExceptionOccurred(env);
    (*env)->ExceptionClear(env);
    if (exception == NULL) {
        return @"unknown error";
    }
    jclass objectClass = (*env)->FindClass(env, "java/lang/Object");
    jmethodID toString = (*env)->GetMethodID(env, objectClass, "toString", "()Ljava/lang/String;");
    jstring text = (jstring)(*env)->CallObjectMethod(env, exception, toString);
    if ((*env)->ExceptionCheck(env) || text == NULL) {
        (*env)->ExceptionClear(env);
        return @"exception";
    }
    const char *chars = (*env)->GetStringUTFChars(env, text, NULL);
    NSString *result = [NSString stringWithUTF8String:chars];
    (*env)->ReleaseStringUTFChars(env, text, chars);
    return result;
}

+ (BOOL)createVm:(JNIEnv **)env error:(NSError **)error {
    NSBundle *bundle = [NSBundle bundleForClass:self];
    NSString *jar = [bundle pathForResource:@"exthost" ofType:@"jar"];
    if (jar == nil) {
        if (error) *error = [self error:@"exthost.jar is missing from the app"];
        return NO;
    }
    NSArray<NSString *> *arguments = @[
        [@"-Djava.class.path=" stringByAppendingString:jar],
        [@"-Djava.io.tmpdir=" stringByAppendingString:NSTemporaryDirectory()],
        [@"-Duser.home=" stringByAppendingString:NSHomeDirectory()],
        @"-Dfile.encoding=UTF-8",
        @"-Xmx384m",
        @"-Xrs",
        @"-Xshare:off",
        @"-XX:-UsePerfData",
        @"-XX:+DisableAttachMechanism",
        @"-XX:+UnlockDiagnosticVMOptions",
        // Extension classes refer to Android classes the host does not have.
        @"-XX:-BytecodeVerificationRemote",
    ];
    JavaVMOption options[arguments.count];
    for (NSUInteger i = 0; i < arguments.count; i++) {
        options[i].optionString = (char *)arguments[i].UTF8String;
        options[i].extraInfo = NULL;
    }
    JavaVMInitArgs args;
    args.version = JNI_VERSION_10;
    args.nOptions = (jint)arguments.count;
    args.options = options;
    args.ignoreUnrecognized = JNI_FALSE;
    NSDate *started = [NSDate date];
    jint rc = JNI_CreateJavaVM(&gJvm, (void **)env, &args);
    if (rc != JNI_OK) {
        gJvm = NULL;
        if (error) *error = [self error:[NSString stringWithFormat:@"JNI_CreateJavaVM failed: %d", rc]];
        return NO;
    }
    NSLog(@"ExtHost: JVM created in %.0f ms", -[started timeIntervalSinceNow] * 1000);

    jclass net = (*(*env))->FindClass(*env, "com/gallery/reader/exthost/jvm/NativeNet");
    if (net == NULL) {
        if (error) *error = [self error:[self takeException:*env]];
        return NO;
    }
    JNINativeMethod methods[] = {
        {(char *)"call", (char *)"([B[B)[[B", (void *)ExtHostNetCall},
    };
    if ((*(*env))->RegisterNatives(*env, net, methods, 1) != JNI_OK) {
        if (error) *error = [self error:[self takeException:*env]];
        return NO;
    }
    jclass embedded = (*(*env))->FindClass(*env, "com/gallery/reader/exthost/jvm/Embedded");
    if (embedded == NULL) {
        if (error) *error = [self error:[self takeException:*env]];
        return NO;
    }
    gEmbedded = (jclass)(*(*env))->NewGlobalRef(*env, embedded);
    return YES;
}

+ (int)startWithConfig:(NSString *)config error:(NSError **)error {
    @synchronized(self) {
        JNIEnv *env = NULL;
        if (gJvm == NULL) {
            if (![self createVm:&env error:error]) {
                return -1;
            }
        } else if ((*gJvm)->AttachCurrentThread(gJvm, (void **)&env, NULL) != JNI_OK) {
            if (error) *error = [self error:@"cannot attach to the JVM"];
            return -1;
        }
        jmethodID start = (*env)->GetStaticMethodID(env, gEmbedded, "start", "(Ljava/lang/String;)I");
        jstring argument = (*env)->NewStringUTF(env, config.UTF8String);
        jint port = (*env)->CallStaticIntMethod(env, gEmbedded, start, argument);
        if ((*env)->ExceptionCheck(env)) {
            if (error) *error = [self error:[self takeException:env]];
            port = -1;
        }
        (*env)->DeleteLocalRef(env, argument);
        (*gJvm)->DetachCurrentThread(gJvm);
        return port;
    }
}

+ (int)restartServer {
    @synchronized(self) {
        JNIEnv *env = NULL;
        if (gJvm == NULL || (*gJvm)->AttachCurrentThread(gJvm, (void **)&env, NULL) != JNI_OK) {
            return -1;
        }
        jmethodID restart = (*env)->GetStaticMethodID(env, gEmbedded, "restartServer", "()I");
        jint port = (*env)->CallStaticIntMethod(env, gEmbedded, restart);
        if ((*env)->ExceptionCheck(env)) {
            NSLog(@"ExtHost: restart failed: %@", [self takeException:env]);
            port = -1;
        }
        (*gJvm)->DetachCurrentThread(gJvm);
        return port;
    }
}

@end
