// LCExtForwardHost: the host half of LCExtForward.
//
// Lives in LiveContainer's GLOBAL tweak folder and is loaded into the
// LiveContainer app itself via Settings → Developer → "Tweaks selber in
// LiveContainer laden" (LCLoadTweaksToSelf). It hooks the import/sign step so
// every PlugIns/*.appex of an opted-in guest app is turned into a loadable
// MH_DYLIB (via lcef_macho.c) *before* LiveContainer signs the bundle with
// ZSign. That removes the need to run patch_appex.py on the IPA beforehand.
//
// It only does the Mach-O conversion; the guest-side forwarding and the
// LiveProcess payload stay in the separate per-app LCExtForward.dylib.
//
// SAFE BY DEFAULT — opt-in only:
//   * No-ops unless it finds itself in the LiveContainer host process (LCUtils
//     present). In a guest it does nothing.
//   * Converts an app only if its bundle id OR .app name is listed in
//     <global tweaks folder>/LCExtForward.apps (one per line; "*" = all;
//     "#" comments). No file / empty file → nothing is touched and every
//     import/sign stays byte-for-byte stock.
//   * Apps without extensions are never affected (no .appex to convert).
//
// After editing LCExtForward.apps, re-sign the app in LiveContainer once.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "lcef_macho.h"

#define LOG(fmt, ...) NSLog(@"[LCExtForwardHost] " fmt, ##__VA_ARGS__)

@protocol LCEFHostUtils
+ (NSProgress *)signAppBundleWithZSign:(NSURL *)path completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;
@end

static void LCEFMachoLog(const char *msg) { LOG(@"%s", msg); }

#pragma mark - Opt-in list

static NSSet<NSString *> *gOptIn; static BOOL gOptInAll;

// The opt-in list sits next to this dylib in the global tweak folder. We locate
// it from our own load path (dladdr): LC_GLOBAL_TWEAKS_FOLDER is already unset by
// TweakLoader before this dylib is loaded, so getenv would miss it.
static NSString *LCEFAppsFile(void) {
    Dl_info info;
    if (dladdr((const void *)&LCEFAppsFile, &info) && info.dli_fname)
        return [[@(info.dli_fname) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"LCExtForward.apps"];
    return nil;
}

static void LCEFLoadOptIn(void) {
    gOptIn = [NSSet set]; gOptInAll = NO;
    NSString *file = LCEFAppsFile();
    NSString *text = file ? [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!text) {
        const char *env = getenv("LC_GLOBAL_TWEAKS_FOLDER");   // fallback if ever still set
        if (env) text = [NSString stringWithContentsOfFile:[@(env) stringByAppendingPathComponent:@"LCExtForward.apps"]
                                                  encoding:NSUTF8StringEncoding error:nil];
    }
    if (!text) return;
    NSMutableSet *set = [NSMutableSet set];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!line.length || [line hasPrefix:@"#"]) continue;
        if ([line isEqualToString:@"*"]) { gOptInAll = YES; continue; }
        [set addObject:line];
    }
    gOptIn = set;
}

static BOOL LCEFShouldConvert(NSURL *bundleURL) {
    if (gOptInAll) return YES;
    if (!gOptIn.count) return NO;
    NSString *appName = [bundleURL.lastPathComponent stringByDeletingPathExtension];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[bundleURL URLByAppendingPathComponent:@"Info.plist"]];
    NSString *bid = info[@"CFBundleIdentifier"];
    if (![bid isKindOfClass:NSString.class]) bid = nil;
    for (NSString *want in gOptIn) {
        // Tolerate a stray ".app" on the entry (e.g. "com.foo.Bar.app" for id "com.foo.Bar").
        NSString *w = [want hasSuffix:@".app"] ? [want substringToIndex:want.length - 4] : want;
        if ([w isEqualToString:appName]) return YES;
        if (bid && ([w isEqualToString:bid] || [bid hasSuffix:w])) return YES;
    }
    return NO;
}

static NSUInteger LCEFConvertAppexes(NSURL *bundleURL) {
    NSURL *plugIns = [bundleURL URLByAppendingPathComponent:@"PlugIns"];
    NSArray<NSURL *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtURL:plugIns
        includingPropertiesForKeys:nil options:0 error:nil];
    NSUInteger n = 0;
    for (NSURL *appex in entries) {
        if (![appex.pathExtension isEqualToString:@"appex"]) continue;
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[appex URLByAppendingPathComponent:@"Info.plist"]];
        NSString *exec = info[@"CFBundleExecutable"];
        if (![exec isKindOfClass:NSString.class]) continue;
        NSString *execPath = [appex URLByAppendingPathComponent:exec].path;
        if (lcef_patch_file(execPath.fileSystemRepresentation)) {
            n++; LOG(@"converted %@/%@", appex.lastPathComponent, exec);
        }
    }
    return n;
}

#pragma mark - Hook

static NSProgress *(*orig_sign)(id, SEL, NSURL *, void (^)(BOOL, NSError *));
static NSProgress *hook_sign(id self, SEL _cmd, NSURL *path, void (^completion)(BOOL, NSError *)) {
    @try {
        LCEFLoadOptIn();
        if (path && LCEFShouldConvert(path)) {
            NSUInteger n = LCEFConvertAppexes(path);
            if (n) LOG(@"%@: %lu appex(es) converted before signing", path.lastPathComponent, (unsigned long)n);
        }
    } @catch (NSException *e) {
        LOG(@"conversion skipped (%@) — signing the bundle unchanged", e.reason);
    }
    return orig_sign(self, _cmd, path, completion);   // ZSign signs the whole bundle, converted appexes included
}

__attribute__((constructor)) static void LCEFHostInstall(void) {
    Class utils = NSClassFromString(@"LCUtils");
    SEL sel = @selector(signAppBundleWithZSign:completionHandler:);
    Method m = utils ? class_getClassMethod(utils, sel) : NULL;
    if (!m) return;   // not the host process (or an incompatible LC) → do nothing
    lcef_macho_log = LCEFMachoLog;
    orig_sign = (void *)method_setImplementation(m, (IMP)hook_sign);
    LOG(@"installed (patch_appex.py no longer needed for opted-in apps)");
}
