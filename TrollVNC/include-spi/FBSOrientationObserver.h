#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBSOrientationUpdate : NSObject
- (NSUInteger)sequenceNumber;
- (NSInteger)rotationDirection;
- (UIInterfaceOrientation)orientation;
- (NSTimeInterval)duration;
@end

@interface FBSOrientationObserver : NSObject
- (UIInterfaceOrientation)activeInterfaceOrientation;
- (void)activeInterfaceOrientationWithCompletion:(id)arg1;
- (void)invalidate;
- (void)setHandler:(void (^)(FBSOrientationUpdate *))handler;
- (void (^)(FBSOrientationUpdate *))handler;
@end

NS_ASSUME_NONNULL_END
