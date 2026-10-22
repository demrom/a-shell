#import <Foundation/Foundation.h>

// One connection owns one real process and one existing native pane handle.
@protocol HerdrPaneWire
- (void)spawn:(NSString *)command cwd:(NSData *)cwd home:(NSData *)home documents:(NSData *)documents probe:(NSString *)probe env:(NSArray<NSString *> *)env cols:(unsigned)cols rows:(unsigned)rows reply:(void (^)(int, NSFileHandle *, int))reply;
- (void)poll:(void (^)(int, int))reply;
- (void)state:(void (^)(int, NSString *, int))reply;
- (void)resize:(unsigned)cols rows:(unsigned)rows reply:(void (^)(int))reply;
- (void)closeInput:(void (^)(int))reply;
- (void)interrupt:(void (^)(int))reply;
- (void)releasePane;
- (void)terminate:(void (^)(void))reply;
@end

NSObject<HerdrPaneWire> *herdr_worker_service(void);
