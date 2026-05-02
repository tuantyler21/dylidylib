/*
 * MeituTweak.dylib — Ad blocker only
 * Suppresses AppLovin, GDT, Pangle/ByteDance ad SDK initialization.
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

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

__attribute__((constructor))
static void MeituTweakInit(void) {
    NSLog(@"[MeituTweak] Loaded ✓");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        installAdHooks();
        NSLog(@"[MeituTweak] Ad hooks active ✓");
    });
}
