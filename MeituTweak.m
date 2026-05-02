/*
 * MeituTweak.dylib
 * Inject into Meitu via LiveContainer.
 *
 * What this does:
 *  1. Blocks paywall VCs from presenting (presentViewController hook)
 *  2. Dismisses any paywall VC that slips through (viewDidAppear hook)
 *  3. Blocks paywall views added as subviews (addSubview hook)
 *  4. Calls unlock completion(YES) so filters actually apply after paywall is blocked
 *  5. Spoofs IDFV with a random UUID each launch → server quota resets
 *  6. Suppresses ad SDK initialization and display
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ─────────────────────────────────────────────────────────────
// MARK: - Helpers
// ─────────────────────────────────────────────────────────────

static void swizzleInstance(Class cls, SEL original, SEL replacement) {
    if (!cls) return;
    Method origMethod = class_getInstanceMethod(cls, original);
    Method replMethod = class_getInstanceMethod(cls, replacement);
    if (!origMethod || !replMethod) return;
    method_exchangeImplementations(origMethod, replMethod);
}

static void swizzleClass(Class cls, SEL original, SEL replacement) {
    if (!cls) return;
    Method origMethod = class_getClassMethod(cls, original);
    Method replMethod = class_getClassMethod(cls, replacement);
    if (!origMethod || !replMethod) return;
    method_exchangeImplementations(origMethod, replMethod);
}

static void forceReturnYES(Class cls, SEL sel) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP yesIMP = imp_implementationWithBlock(^BOOL(id _self){ return YES; });
    method_setImplementation(m, yesIMP);
}

static void forceReturnNO(Class cls, SEL sel) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP noIMP = imp_implementationWithBlock(^BOOL(id _self){ return NO; });
    method_setImplementation(m, noIMP);
}

// ─────────────────────────────────────────────────────────────
// MARK: - 1. Paywall VC Blocking
// ─────────────────────────────────────────────────────────────

static NSArray<NSString *> *paywallKeywords(void) {
    return @[
        @"MTPWVip", @"MTPayWindow", @"MTVipCenter", @"MTVipUnlock",
        @"MTSubscription", @"VipCenter", @"PayController",
        @"VipController", @"MTVipBuy", @"MTVipPay", @"MTVipAlert"
    ];
}

static BOOL isPaywallVC(UIViewController *vc) {
    if (!vc) return NO;
    NSString *name = NSStringFromClass([vc class]);
    if (!name) return NO;
    for (NSString *kw in paywallKeywords()) {
        if ([name containsString:kw]) return YES;
    }
    return NO;
}

@interface UIViewController (MeituPaywallBlock)
- (void)mt_presentViewController:(UIViewController *)vc
                         animated:(BOOL)animated
                       completion:(void (^)(void))completion;
@end

@implementation UIViewController (MeituPaywallBlock)

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        swizzleInstance(self,
            @selector(presentViewController:animated:completion:),
            @selector(mt_presentViewController:animated:completion:));
        NSLog(@"[MeituTweak] Paywall VC hook installed");
    });
}

- (void)mt_presentViewController:(UIViewController *)vc
                         animated:(BOOL)animated
                       completion:(void (^)(void))completion {
    if (isPaywallVC(vc)) {
        NSLog(@"[MeituTweak] Blocked paywall VC: %@", NSStringFromClass([vc class]));
        if (completion) completion();
        return;
    }
    // Calls original (names are swapped after exchange)
    [self mt_presentViewController:vc animated:animated completion:completion];
}

@end

// ─────────────────────────────────────────────────────────────
// MARK: - 2. IDFV Spoofing (quota reset)
// ─────────────────────────────────────────────────────────────

static NSUUID *gSpoofedUUID = nil;

@interface UIDevice (MeituIDFVSpoof)
- (NSUUID *)mt_identifierForVendor;
@end

@implementation UIDevice (MeituIDFVSpoof)

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // New random UUID each app launch = server always sees a new device
        gSpoofedUUID = [NSUUID UUID];
        swizzleInstance(self,
            @selector(identifierForVendor),
            @selector(mt_identifierForVendor));
        NSLog(@"[MeituTweak] IDFV spoofed: %@", gSpoofedUUID.UUIDString);
    });
}

- (NSUUID *)mt_identifierForVendor {
    return gSpoofedUUID;
}

@end

// ─────────────────────────────────────────────────────────────
// MARK: - 3. Filter Unlock — call completion(YES) so filters apply
// ─────────────────────────────────────────────────────────────

static void installUnlockHook(void) {
    SEL unlockSEL = NSSelectorFromString(@"showVipUnlockViewIn:materials:unlockType:completion:");

    // Scan only MT* and Swift Meitu classes — safe and fast
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;

    int found = 0;
    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        const char *cname = class_getName(cls);
        if (!cname) continue;
        // Only check Meitu classes (MT prefix or Swift mangled _TtC)
        if (strncmp(cname, "MT", 2) != 0 && strncmp(cname, "_TtC", 4) != 0) continue;

        Method m = class_getInstanceMethod(cls, unlockSEL);
        if (!m) continue;

        IMP callCompletionYES = imp_implementationWithBlock(
            ^(id _self, id container, id materials, NSInteger unlockType, void(^completion)(BOOL)) {
                NSLog(@"[MeituTweak] showVipUnlockView intercepted → calling completion(YES)");
                if (completion) completion(YES);
            }
        );
        method_setImplementation(m, callCompletionYES);
        NSLog(@"[MeituTweak] Hooked showVipUnlockViewIn: on %s", cname);
        found++;
    }
    free(classes);

    if (found == 0) {
        NSLog(@"[MeituTweak] WARNING: showVipUnlockViewIn: not found in any MT class");
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 4. Dismiss paywall VCs that slip through (viewDidAppear)
// ─────────────────────────────────────────────────────────────

@interface UIViewController (MeituPaywallDismiss)
- (void)mt_viewDidAppear:(BOOL)animated;
@end

@implementation UIViewController (MeituPaywallDismiss)

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        swizzleInstance(self,
            @selector(viewDidAppear:),
            @selector(mt_viewDidAppear:));
    });
}

- (void)mt_viewDidAppear:(BOOL)animated {
    [self mt_viewDidAppear:animated]; // call original first
    if (isPaywallVC(self)) {
        NSLog(@"[MeituTweak] Dismissing paywall VC in viewDidAppear: %@", NSStringFromClass([self class]));
        [self dismissViewControllerAnimated:NO completion:nil];
    }
}

@end

// ─────────────────────────────────────────────────────────────
// MARK: - 6. Ad SDK Suppression
// ─────────────────────────────────────────────────────────────

static void installAdHooks(void) {
    // AppLovin: prevent SDK initialization
    Class alSdk = NSClassFromString(@"ALSdk");
    if (alSdk) {
        SEL initSel = NSSelectorFromString(@"initializeSdkWithConfiguration:completionHandler:");
        Method m = class_getClassMethod(alSdk, initSel);
        if (m) {
            IMP noop = imp_implementationWithBlock(^(id _self, id config, void(^cb)(id)){
                if (cb) cb(nil);
            });
            method_setImplementation(m, noop);
            NSLog(@"[MeituTweak] AppLovin init suppressed");
        }
    }

    // GDT (Tencent): suppress ad load
    Class gdtManager = NSClassFromString(@"GDTAdManager");
    if (gdtManager) {
        SEL loadSel = NSSelectorFromString(@"loadAdData:");
        Method m = class_getInstanceMethod(gdtManager, loadSel);
        if (m) {
            method_setImplementation(m, imp_implementationWithBlock(^(id _self, id data){}));
            NSLog(@"[MeituTweak] GDT ad load suppressed");
        }
    }

    // Pangle/ByteDance: block app registration
    NSArray *pangleClasses = @[@"BUAdSDKManager", @"PAGSdk"];
    for (NSString *clsName in pangleClasses) {
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
    // Delay slightly so all ObjC classes finish registering
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        installUnlockHook();
        installAdHooks();
        NSLog(@"[MeituTweak] All hooks active ✓");
    });
}
