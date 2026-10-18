#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The JVM in this process and the extension host on it.
@interface ExtHostJVM : NSObject

/// Starts the JVM once, then the host with its JSON configuration; the
/// host's port, or -1 with `error` set.
+ (int)startWithConfig:(NSString *)config error:(NSError **)error;

/// Opens the host's port again (iOS may close it while the app is in the
/// background); the port, or -1.
+ (int)restartServer;

@end

NS_ASSUME_NONNULL_END
