#import <Foundation/Foundation.h>

#include <jni.h>

// HTTP for the host's OkHttp on iOS (see NativeTransport.kt): one exchange per
// call, carried by NSURLSession, which does TLS and decompression natively.
// Redirects are not followed and cookies are neither sent nor kept here:
// OkHttp does both, so its interceptors see every step.

@interface ExtHostNetDelegate : NSObject <NSURLSessionTaskDelegate>
@end

@implementation ExtHostNetDelegate
- (void)URLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                    newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}
@end

static NSMutableDictionary<NSString *, NSURLSession *> *gSessions;

/// One session per proxy setting: `http://host:port`, `socks5://host:port`, or empty.
static NSURLSession *ExtHostSession(NSString *proxy) {
    @synchronized([ExtHostNetDelegate class]) {
        if (gSessions == nil) {
            gSessions = [NSMutableDictionary dictionary];
        }
        NSURLSession *session = gSessions[proxy];
        if (session != nil) {
            return session;
        }
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.HTTPShouldSetCookies = NO;
        configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
        configuration.HTTPCookieStorage = nil;
        configuration.URLCache = nil;
        configuration.HTTPMaximumConnectionsPerHost = 6;
        NSURLComponents *url = proxy.length > 0 ? [NSURLComponents componentsWithString:proxy] : nil;
        if (url.host != nil && url.port != nil) {
            NSString *scheme = url.scheme.lowercaseString;
            if ([scheme hasPrefix:@"socks"]) {
                configuration.connectionProxyDictionary = @{
                    (NSString *)kCFStreamPropertySOCKSProxyHost: url.host,
                    (NSString *)kCFStreamPropertySOCKSProxyPort: url.port,
                };
            } else {
                configuration.connectionProxyDictionary = @{
                    @"HTTPEnable": @YES,
                    @"HTTPProxy": url.host,
                    @"HTTPPort": url.port,
                    @"HTTPSEnable": @YES,
                    @"HTTPSProxy": url.host,
                    @"HTTPSPort": url.port,
                };
            }
        }
        session = [NSURLSession sessionWithConfiguration:configuration delegate:[ExtHostNetDelegate new] delegateQueue:nil];
        gSessions[proxy] = session;
        return session;
    }
}

static NSData *ExtHostJsonData(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil] ?: [NSData data];
}

static jbyteArray ExtHostByteArray(JNIEnv *env, NSData *data) {
    jbyteArray array = (*env)->NewByteArray(env, (jsize)data.length);
    (*env)->SetByteArrayRegion(env, array, 0, (jsize)data.length, (const jbyte *)data.bytes);
    return array;
}

static NSData *ExtHostData(JNIEnv *env, jbyteArray array) {
    if (array == NULL) {
        return nil;
    }
    jsize length = (*env)->GetArrayLength(env, array);
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)length];
    (*env)->GetByteArrayRegion(env, array, 0, length, (jbyte *)data.mutableBytes);
    return data;
}

/// Response headers as name/value pairs. NSHTTPURLResponse joins repeated
/// headers into one; Set-Cookie is split again into one header per cookie,
/// and the encoding headers of a body NSURLSession already decompressed are
/// left out.
static NSArray<NSArray<NSString *> *> *ExtHostHeaders(NSHTTPURLResponse *response) {
    NSMutableArray<NSArray<NSString *> *> *headers = [NSMutableArray array];
    [response.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        NSString *lower = name.lowercaseString;
        if ([lower isEqualToString:@"content-encoding"] || [lower isEqualToString:@"content-length"] || [lower isEqualToString:@"set-cookie"]) {
            return;
        }
        [headers addObject:@[name, value]];
    }];
    NSArray<NSHTTPCookie *> *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:response.allHeaderFields forURL:response.URL];
    for (NSHTTPCookie *cookie in cookies) {
        NSMutableString *line = [NSMutableString stringWithFormat:@"%@=%@; Path=%@", cookie.name, cookie.value, cookie.path ?: @"/"];
        // A leading dot: the cookie named a domain; without one it is for this host only.
        if ([cookie.domain hasPrefix:@"."]) {
            [line appendFormat:@"; Domain=%@", cookie.domain];
        }
        if (cookie.expiresDate != nil) {
            [line appendFormat:@"; Max-Age=%.0f", MAX(0, cookie.expiresDate.timeIntervalSinceNow)];
        }
        if (cookie.isSecure) [line appendString:@"; Secure"];
        if (cookie.isHTTPOnly) [line appendString:@"; HttpOnly"];
        [headers addObject:@[@"Set-Cookie", line]];
    }
    return headers;
}

jobjectArray ExtHostNetCall(JNIEnv *env, jclass cls, jbyteArray metaBytes, jbyteArray bodyBytes) {
    @autoreleasepool {
        NSDictionary *meta = [NSJSONSerialization JSONObjectWithData:ExtHostData(env, metaBytes) options:0 error:nil];
        NSURL *url = [NSURL URLWithString:meta[@"url"]];
        NSData *answer;
        NSData *body = nil;
        if (url == nil) {
            answer = ExtHostJsonData(@{@"error": [NSString stringWithFormat:@"bad URL %@", meta[@"url"]]});
        } else {
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
            request.HTTPMethod = meta[@"method"] ?: @"GET";
            request.HTTPShouldHandleCookies = NO;
            NSNumber *timeout = meta[@"timeoutMs"];
            request.timeoutInterval = timeout != nil ? timeout.doubleValue / 1000 : 30;
            for (NSArray<NSString *> *header in meta[@"headers"]) {
                [request addValue:header[1] forHTTPHeaderField:header[0]];
            }
            request.HTTPBody = ExtHostData(env, bodyBytes);

            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            __block NSData *received = nil;
            __block NSHTTPURLResponse *response = nil;
            __block NSError *failure = nil;
            NSURLSessionDataTask *task = [ExtHostSession(meta[@"proxy"] ?: @"") dataTaskWithRequest:request
                                                                                   completionHandler:^(NSData *data, NSURLResponse *r, NSError *error) {
                received = data;
                response = (NSHTTPURLResponse *)r;
                failure = error;
                dispatch_semaphore_signal(done);
            }];
            [task resume];
            dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

            if (failure != nil && response == nil) {
                answer = ExtHostJsonData(@{@"error": failure.localizedDescription ?: @"request failed"});
            } else {
                answer = ExtHostJsonData(@{
                    @"code": @(response.statusCode),
                    @"message": [NSHTTPURLResponse localizedStringForStatusCode:response.statusCode],
                    @"headers": ExtHostHeaders(response),
                    @"url": response.URL.absoluteString ?: @"",
                });
                body = received;
            }
        }
        jclass byteArrayClass = (*env)->FindClass(env, "[B");
        jobjectArray result = (*env)->NewObjectArray(env, 2, byteArrayClass, NULL);
        (*env)->SetObjectArrayElement(env, result, 0, ExtHostByteArray(env, answer));
        if (body != nil) {
            (*env)->SetObjectArrayElement(env, result, 1, ExtHostByteArray(env, body));
        }
        return result;
    }
}
