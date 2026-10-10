#import "ObjCExceptionHandler.h"

@implementation ObjCExceptionHandler

+ (nullable NSString *)catchExceptionInBlock:(void (NS_NOESCAPE ^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception.reason ?: exception.name;
    }
}

@end
