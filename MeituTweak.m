/*
 * MeituTweak.dylib — Final build
 * 1. Ad SDK suppression (AppLovin, GDT, Pangle/ByteDance)
 * 2. IDFV spoof — random UUID each launch → server quota resets
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ─────────────────────────────────────────────────────────────
// MARK: - IDFV Spoof
// ─────────────────────────────────────────────────────────────

static NSUUID *gSpoofedUUID = nil;

@interface UIDevice (MeituIDFVSpoof)
- (NSUUID *)mt_identifierForVendor;
@end

@implementation UIDevice (MeituIDFVSpoof)
+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSpoofedUUID = [NSUUID UUID];
        Method orig = class_getInstanceMethod(self, @selector(identifierForVendor));
        Method repl = class_getInstanceMethod(self, @selector(mt_identifierForVendor));
        method_exchangeImplementations(orig, repl);
        NSLog(@"[MeituTweak] IDFV spoofed: %@", gSpoofedUUID.UUIDString);
    });
}
- (NSUUID *)mt_identifierForVendor {
    return gSpoofedUUID;
}
@end

// ─────────────────────────────────────────────────────────────
// MARK: - Ad SDK Suppression
// ─────────────────────────────────────────────────────────────

static void installAdHooks(void) {
    // AppLovin
    Class alSdk = NSClassFromString(@"ALSdk");
    if (alSdk) {
        SEL sel = NSSelectorFromString(@"initializeSdkWithConfiguration:completionHandler:");
        Method m = class_getClassMethod(alSdk, sel);
        if (m) {
            method_setImplementation(m, imp_implementationWithBlock(^(id _self, id config, void(^cb)(id)){
                if (cb) cb(nil);
            }));
            NSLog(@"[MeituTweak] AppLovin suppressed");
        }
    }

    // GDT (Tencent)
    Class gdtManager = NSClassFromString(@"GDTAdManager");
    if (gdtManager) {
        Method m = class_getInstanceMethod(gdtManager, NSSelectorFromString(@"loadAdData:"));
        if (m) {
            method_setImplementation(m, imp_implementationWithBlock(^(id _self, id data){}));
            NSLog(@"[MeituTweak] GDT suppressed");
        }
    }

    // Pangle / ByteDance
    for (NSString *clsName in @[@"BUAdSDKManager", @"PAGSdk"]) {
        Class cls = NSClassFromString(clsName);
        if (!cls) continue;
        for (NSString *sel in @[@"setAppID:", @"startWithAppID:", @"startWithConfig:"]) {
            Method m = class_getClassMethod(cls, NSSelectorFromString(sel));
            if (m) {
                method_setImplementation(m, imp_implementationWithBlock(^(id _self, id arg){}));
                NSLog(@"[MeituTweak] %@ %@ suppressed", clsName, sel);
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Entry Point
// ─────────────────────────────────────────────────────────────

__attribute__((constructor))
static void MeituTweakInit(void) {
    NSLog(@"[MeituTweak] Loaded ✓");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        installAdHooks();
        NSLog(@"[MeituTweak] All hooks active ✓");
    });
}
