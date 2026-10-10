#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges Objective-C @try/@catch into Swift.
///
/// AVAudioEngine.connect(_:to:format:) throws NSException (not Swift Error)
/// when the format is incompatible with the audio hardware. Swift's do/catch
/// cannot intercept NSExceptions, so they propagate as SIGABRT. This helper
/// lets us catch them gracefully.
@interface ObjCExceptionHandler : NSObject

/// Executes `block` inside @try/@catch.
/// Returns nil on success, or the exception's reason string on failure.
+ (nullable NSString *)catchExceptionInBlock:(void (NS_NOESCAPE ^)(void))block;

@end

NS_ASSUME_NONNULL_END
