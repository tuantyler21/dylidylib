/*
 * MeituTweak.dylib
 * Inject into Meitu via LiveContainer.
 *
 * What this does:
 *  1. Blocks all VIP/paywall ViewControllers from presenting
 *  2. Forces VIP status to YES on all gate-keeping classes
 *  3. Spoofs IDFV with a random UUID each launch → server quota resets
 *  4. Suppresses ad SDK initialization and display
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
    NSString *name = NSStringFromClass([vc class]);
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
// MARK: - 3. VIP Status Forcing
// ─────────────────────────────────────────────────────────────

// Called after a short delay so Swift classes are fully registered
static void installVIPHooks(void) {
    // All known VIP gate classes (ObjC + Swift mangled names)
    NSArray<NSString *> *vipClasses = @[
        @"_TtC11MTVIPModule12MTVipService",
        @"MTVipService",
        @"MTUserVipInfo",
        @"MTSubscriptionVipInfo",
        @"MTVipManager",
        @"MTVIPManager",
    ];

    // Selectors that should return YES
    NSArray<NSString *> *yesSelectors = @[
        @"isCurrentUserVip",
        @"isCurrentUserSVip",
        @"isCurrentReallyUserVip",
        @"isVip",
        @"isVipUser",
        @"isSVip",
        @"isPremium",
        @"isSubscribed",
        @"inTrialPeriod",
        @"hasVip",
    ];

    // Selectors that should return NO (negative/limit guards)
    NSArray<NSString *> *noSelectors = @[
        @"isFreeUser",
        @"isLimitTrial",
        @"shouldShowVipAlert",
        @"needsUpgrade",
    ];

    for (NSString *className in vipClasses) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        for (NSString *selName in yesSelectors) {
            forceReturnYES(cls, NSSelectorFromString(selName));
        }
        for (NSString *selName in noSelectors) {
            forceReturnNO(cls, NSSelectorFromString(selName));
        }
        NSLog(@"[MeituTweak] VIP hooks applied on %@", className);
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 4. Ad SDK Suppression
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
        installVIPHooks();
        installAdHooks();
        NSLog(@"[MeituTweak] All hooks active ✓");
    });
}
