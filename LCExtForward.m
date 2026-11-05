// LCExtForward: lets a guest app in LiveContainer start its own private app
// extensions (e.g. Madeira's MadeiraMemoryHost) by forwarding them to
// LiveContainer's LiveProcess.appex.
//
// Two roles, one dylib:
//  1. Guest process (loaded by TweakLoader): hooks +[NSExtension
//     extensionWithIdentifier:error:]. When the system has no extension with
//     that identifier but the guest app has one in its PlugIns folder, it
//     returns a proxy around LiveProcess's NSExtension instead. The proxy's
//     -beginExtensionRequestWithInputItems:completion: adds LiveProcess's
//     custom-payload keys to the first item's userInfo (the guest's own keys,
//     such as Madeira's "endpoint", stay as they are); every other message
//     goes to the real extension.
//     LiveProcess cannot open files in LiveContainer's Documents before it has
//     the request's bookmarks, so the payload is a copy of this dylib in the
//     app group, and the request carries bookmarks for the guest app and its
//     data container.
//  2. LiveProcess (loaded as customPayloadDylib): LCExtForwardMain loads the
//     guest appex, makes it the main bundle, creates its
//     NSExtensionPrincipalClass and hands it LiveProcess's extension context.
//
// Log: <guest data container>/Documents/LCExtForward.log (both roles), and NSLog.
//
// Limits: only extensions the guest starts itself through NSExtension. All of
// them run on LiveProcess's extension point (com.apple.ar.viewer). Storyboard
// based extensions (NSExtensionMainStoryboard) are not supported. The appex
// executable must be dlopen-able: run patch_appex.py on the IPA first. The
// LiveProcess side runs without JIT, so this dylib and the appex must be signed
// with LiveContainer's certificate even when the guest app itself uses JIT.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdio.h>

static NSString *const kAppexPathKey = @"LCExtForwardAppexPath";
static NSString *const kLogPathKey = @"LCExtForwardLogPath";
static NSString *const kBookmarksKey = @"LCExtForwardBookmarks";

// NSURLBookmarkCreationWithSecurityScope; the iOS SDK hides it, LiveContainer uses the raw value too.
static const NSURLBookmarkCreationOptions kSecurityScope = 1 << 11;

// Private API, declared as protocols so no private class symbol is linked.
@protocol LCEFSharedUtils
+ (NSString *)liveProcessBundleIdentifier;
+ (NSURL *)appGroupPath;
@end
@protocol LCEFUserDefaults
+ (NSBundle *)lcMainBundle;
+ (NSDictionary *)guestAppInfo;
+ (NSString *)lcAppGroupPath;
@end
@protocol LCEFLiveProcessHandler
+ (NSExtensionContext *)extensionContext;
+ (NSDictionary *)retrievedAppInfo;
@end

#pragma mark - Logging

// Off by default. Build with -DLCEF_LOG=1 to get NSLog output and a log file at
// <data container>/Documents/LCExtForward.log for debugging.
#ifndef LCEF_LOG
#define LCEF_LOG 0
#endif

#if LCEF_LOG
static NSString *gLogPath;
static void LCEFLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void LCEFLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[LCExtForward] %@", message);
    if (!gLogPath) return;
    FILE *file = fopen(gLogPath.fileSystemRepresentation, "a");
    if (!file) return;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    fprintf(file, "%s [%d] %s\n", [formatter stringFromDate:NSDate.date].UTF8String, getpid(), message.UTF8String);
    fclose(file);
}
#define LOG(...) LCEFLog(__VA_ARGS__)
#else
#define LOG(...) do {} while (0)
#endif

#pragma mark - Helpers

static NSString *LCEFGuestAppPath(void);

static NSString *LCEFSelfPath(void) {
    Dl_info info;
    if (dladdr((const void *)&LCEFSelfPath, &info) && info.dli_fname) return @(info.dli_fname);
    return nil;
}

static NSString *LCEFAppGroupPath(void) {
    Class defaults = NSUserDefaults.class;
    if ([defaults respondsToSelector:@selector(lcAppGroupPath)]) {
        NSString *path = [(Class<LCEFUserDefaults>)defaults lcAppGroupPath];
        if (path.length) return path;
    }
    Class utils = NSClassFromString(@"LCSharedUtils");
    if ([utils respondsToSelector:@selector(appGroupPath)])
        return [(Class<LCEFSharedUtils>)utils appGroupPath].path;
    return nil;
}

/// LiveProcess opens its payload before it takes the sandbox extensions the
/// request carries, so it cannot reach this dylib in LiveContainer's Documents.
/// It can reach the app group, so the dylib copies itself there (with its
/// signature, which is part of the file). A new file each time (atomic write)
/// keeps a mapped old copy valid.
static NSString *LCEFPayloadPath(NSString *selfPath) {
    NSString *group = LCEFAppGroupPath();
    if (!group || !selfPath) return nil;
    if ([selfPath hasPrefix:group]) return selfPath;
    NSString *dir = [group stringByAppendingPathComponent:@"LiveContainer/LCExtForward"];
    NSString *dest = [dir stringByAppendingPathComponent:@"LCExtForward.dylib"];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSData *mine = [NSData dataWithContentsOfFile:selfPath];
    if (!mine) {
        LOG(@"cannot read %@", selfPath);
        return nil;
    }
    if ([[NSData dataWithContentsOfFile:dest] isEqualToData:mine]) return dest;
    NSError *error = nil;
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if (![mine writeToFile:dest options:NSDataWritingAtomic error:&error]) {
        LOG(@"copying the dylib to the app group failed: %@", error);
        return nil;
    }
    [fm setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:dest error:nil];
    LOG(@"copied the dylib to %@", dest);
    return dest;
}

/// Same problem as the dylib, for the appex: the guest's Documents folder lets
/// LiveProcess read the appex but not map it as executable code (the sandbox
/// blocks mmap(PROT_EXEC) there). The app group allows it — that is where the
/// payload dylib itself loaded from — so the whole .appex bundle is staged
/// next to the dylib and LiveProcess loads it from there. The LiveContainer
/// signature on each Mach-O is part of the file, so copying preserves it.
/// Returns the staged appex path, or the original on failure (so the loader's
/// own error still shows the real reason).
/// One-time, idempotent copy of the guest app's Frameworks into the staging
/// root, so the helper's `@rpath/../../Frameworks` (XUL, GeckoView.framework, …)
/// resolves to a location LiveProcess may executably map (the app group). Keyed
/// on the source Frameworks mtime, so it recopies only after an app update/re-sign.
static void LCEFStageFrameworks(NSString *guestFrameworks, NSString *root) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:guestFrameworks isDirectory:&isDir] || !isDir) return;
    NSString *dest = [root stringByAppendingPathComponent:@"Frameworks"];
    NSString *stampFile = [root stringByAppendingPathComponent:@".fwstamp"];
    NSDate *mtime = [fm attributesOfItemAtPath:guestFrameworks error:nil].fileModificationDate;
    NSString *stamp = [NSString stringWithFormat:@"%.0f", mtime.timeIntervalSince1970];
    NSString *have = [NSString stringWithContentsOfFile:stampFile encoding:NSUTF8StringEncoding error:nil];
    if ([have isEqualToString:stamp] && [fm fileExistsAtPath:dest]) return;   // already staged this version

    [fm removeItemAtPath:dest error:nil];
    NSError *error = nil;
    if (![fm copyItemAtPath:guestFrameworks toPath:dest error:&error]) {
        LOG(@"staging Frameworks failed: %@", error);
        return;
    }
    [stamp writeToFile:stampFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    LOG(@"staged Frameworks (%@) to %@", mtime, dest);
}

/// Stage the appex into a minimal bundle layout in the app group:
///   <root>/PlugIns/<name>.appex   and   <root>/Frameworks/
/// so that the helper's `@rpath/../../Frameworks` resolves next to it. Self-
/// contained helpers (Madeira) simply have no Frameworks to stage.
static NSString *LCEFStageAppex(NSString *appexPath) {
    NSString *group = LCEFAppGroupPath();
    if (!group || !appexPath) return appexPath;
    if ([appexPath hasPrefix:group]) return appexPath;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *appPath = LCEFGuestAppPath();
    NSString *stem = [appPath.lastPathComponent stringByDeletingPathExtension] ?: @"app";
    NSString *root = [group stringByAppendingPathComponent:[@"LiveContainer/LCExtForward" stringByAppendingPathComponent:stem]];
    NSString *plugIns = [root stringByAppendingPathComponent:@"PlugIns"];
    NSString *dest = [plugIns stringByAppendingPathComponent:appexPath.lastPathComponent];

    LCEFStageFrameworks([appPath stringByAppendingPathComponent:@"Frameworks"], root);

    NSBundle *srcBundle = [NSBundle bundleWithPath:appexPath];
    NSData *srcExec = srcBundle.executablePath ? [NSData dataWithContentsOfFile:srcBundle.executablePath] : nil;
    if (!srcExec) {
        LOG(@"cannot read the appex executable at %@", appexPath);
        return appexPath;
    }
    NSBundle *dstBundle = [NSBundle bundleWithPath:dest];
    // Reuse an identical staged copy so a still-running older LiveProcess keeps its file.
    if (dstBundle.executablePath && [[NSData dataWithContentsOfFile:dstBundle.executablePath] isEqualToData:srcExec])
        return dest;

    [fm createDirectoryAtPath:plugIns withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:dest error:nil];
    NSError *error = nil;
    if (![fm copyItemAtPath:appexPath toPath:dest error:&error]) {
        LOG(@"staging the appex to the app group failed: %@", error);
        return appexPath;
    }
    LOG(@"staged %@ to %@", appexPath.lastPathComponent, dest);
    return dest;
}

/// Security-scoped bookmarks for LiveProcess, as LiveContainer sends them when
/// multitasking: the guest app (for the appex) and its data container (for the log).
static NSArray<NSData *> *LCEFBookmarks(void) {
    NSMutableArray *bookmarks = [NSMutableArray array];
    const char *home = getenv("HOME");
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithObject:[NSURL fileURLWithPath:LCEFGuestAppPath()]];
    if (home) [urls addObject:[NSURL fileURLWithPath:@(home)]];
    for (NSURL *url in urls) {
        NSError *error = nil;
        NSData *data = [url bookmarkDataWithOptions:kSecurityScope includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
        if (data) [bookmarks addObject:data];
        else LOG(@"no bookmark for %@: %@", url.path, error);
    }
    return bookmarks;
}

/// The guest .app: the main bundle, or the app around it when the main bundle
/// is an appex (inside LiveProcess after LCExtForwardMain switched it).
static NSString *LCEFGuestAppPath(void) {
    NSString *path = NSBundle.mainBundle.bundlePath;
    if ([path.pathExtension isEqualToString:@"appex"])
        path = path.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    return path;
}

static NSString *LCEFPlugInsPath(void) {
    return [LCEFGuestAppPath() stringByAppendingPathComponent:@"PlugIns"];
}

/// The guest appex for `identifier`. Matches the appex's bundle ID exactly, or
/// by the part after the app's bundle ID: with LiveContainer's "use LC bundle
/// ID" option the app asks for <LC ID>.MemoryHost while its appex is still
/// <original ID>.MemoryHost.
static NSString *LCEFFindGuestAppex(NSString *identifier) {
    NSString *suffix = nil;
    NSString *mainID = NSBundle.mainBundle.bundleIdentifier;
    NSString *prefix = mainID ? [mainID stringByAppendingString:@"."] : nil;
    if (prefix && [identifier hasPrefix:prefix] && identifier.length > prefix.length)
        suffix = [identifier substringFromIndex:prefix.length - 1];   // keeps the leading dot

    NSString *plugIns = LCEFPlugInsPath();
    NSString *suffixMatch = nil;
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:plugIns error:nil]) {
        if (![name.pathExtension isEqualToString:@"appex"]) continue;
        NSString *path = [plugIns stringByAppendingPathComponent:name];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
        NSString *appexID = info[@"CFBundleIdentifier"];
        if (![appexID isKindOfClass:NSString.class]) continue;
        if ([appexID isEqualToString:identifier]) return path;
        if (suffix && !suffixMatch && [appexID hasSuffix:suffix]) suffixMatch = path;
    }
    return suffixMatch;
}

/// LiveContainer replaces NSBundle.mainBundle with the guest app, so
/// LCSharedUtils.liveProcessBundleIdentifier (which looks in the main bundle's
/// PlugIns) misses LiveProcess. LiveContainer keeps its own bundle as lcMainBundle.
static NSString *LCEFLiveProcessIdentifier(void) {
    Class defaults = NSUserDefaults.class;
    if ([defaults respondsToSelector:@selector(lcMainBundle)]) {
        NSBundle *lc = [(Class<LCEFUserDefaults>)defaults lcMainBundle];
        // Multitask mode: the guest already runs inside LiveProcess.appex.
        if ([lc.bundlePath.lastPathComponent isEqualToString:@"LiveProcess.appex"] && lc.bundleIdentifier)
            return lc.bundleIdentifier;
        NSString *path = [lc.builtInPlugInsPath stringByAppendingPathComponent:@"LiveProcess.appex"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
        if ([info[@"CFBundleIdentifier"] isKindOfClass:NSString.class]) return info[@"CFBundleIdentifier"];
        LOG(@"no LiveProcess.appex in %@", lc.bundlePath);
    }
    Class utils = NSClassFromString(@"LCSharedUtils");
    if ([utils respondsToSelector:@selector(liveProcessBundleIdentifier)])
        return [(Class<LCEFSharedUtils>)utils liveProcessBundleIdentifier];
    return nil;
}

#pragma mark - Guest side

static NSString *gSelfPath;      // where TweakLoader loaded this dylib from
static NSString *gPayloadPath;   // the copy LiveProcess can open (app group)

@protocol LCEFExtension
// Async variant (e.g. Madeira) and the synchronous one (e.g. Reynard / Gecko child processes).
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *identifier))completion;
- (NSUUID *)beginExtensionRequestWithInputItems:(NSArray *)items error:(NSError **)error;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *identifier))block;
- (void)setRequestCancellationBlock:(void (^)(NSUUID *identifier, NSError *error))block;
@end

/// Stands in for LiveProcess's NSExtension. The object +extensionWithIdentifier:
/// returns can be a private subclass that overrides the request methods, so a
/// hook on NSExtension itself never sees the request; a proxy always does.
/// Everything else goes straight to the real extension.
@interface LCEFExtensionProxy : NSProxy
- (instancetype)initWithExtension:(id)extension appex:(NSString *)appex;
@end

@implementation LCEFExtensionProxy {
    id _target;
    NSString *_appex;
}

- (instancetype)initWithExtension:(id)extension appex:(NSString *)appex {
    _target = extension;
    _appex = [appex copy];
    return self;
}

/// Inject LiveProcess's custom-payload keys into the first input item's
/// userInfo, keeping the guest app's own keys (Madeira's "endpoint", Reynard's
/// "ReynardXPCListenerEndpoint", …). Shared by both begin-request variants.
- (NSArray *)lcef_forwardItems:(NSArray *)items {
    NSMutableArray *newItems = [NSMutableArray arrayWithArray:items ?: @[]];
    NSExtensionItem *first = newItems.firstObject;
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithDictionary:first.userInfo ?: @{}];
    userInfo[@"customPayloadDylib"] = gPayloadPath;
    userInfo[@"customPayloadEntry"] = @"LCExtForwardMain";
    userInfo[kBookmarksKey] = LCEFBookmarks();
    userInfo[kAppexPathKey] = LCEFStageAppex(_appex);
#if LCEF_LOG
    if (gLogPath) userInfo[kLogPathKey] = gLogPath;
#endif
    NSExtensionItem *forwarded = [NSExtensionItem new];
    forwarded.userInfo = userInfo;   // userInfo also carries title, text and attachments
    if (newItems.count) newItems[0] = forwarded; else [newItems addObject:forwarded];
    LOG(@"starting %@ in LiveProcess (%@)", _appex.lastPathComponent, [_target class]);
    return newItems;
}

- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *))completion {
    NSArray *newItems = [self lcef_forwardItems:items];
    NSString *name = _appex.lastPathComponent;
    (void)name;
    [(id<LCEFExtension>)_target beginExtensionRequestWithInputItems:newItems completion:^(NSUUID *identifier) {
        LOG(@"%@: request %@", name, identifier ? @"started" : @"failed to start (no identifier)");
        if (completion) completion(identifier);
    }];
}

- (NSUUID *)beginExtensionRequestWithInputItems:(NSArray *)items error:(NSError **)error {
    NSArray *newItems = [self lcef_forwardItems:items];
    NSUUID *identifier = [(id<LCEFExtension>)_target beginExtensionRequestWithInputItems:newItems error:error];
    LOG(@"%@: request %@ (error %@)", _appex.lastPathComponent,
        identifier ? @"started" : @"failed to start", error ? *error : nil);
    return identifier;
}

- (void)setRequestInterruptionBlock:(void (^)(NSUUID *))block {
    NSString *name = _appex.lastPathComponent;
    (void)name;
    [(id<LCEFExtension>)_target setRequestInterruptionBlock:^(NSUUID *identifier) {
        LOG(@"%@: LiveProcess exited (request interrupted)", name);
        if (block) block(identifier);
    }];
}

- (void)setRequestCancellationBlock:(void (^)(NSUUID *, NSError *))block {
    NSString *name = _appex.lastPathComponent;
    (void)name;
    [(id<LCEFExtension>)_target setRequestCancellationBlock:^(NSUUID *identifier, NSError *error) {
        LOG(@"%@: request cancelled: %@", name, error);
        if (block) block(identifier, error);
    }];
}

- (id)forwardingTargetForSelector:(SEL)selector { return _target; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector { return [_target methodSignatureForSelector:selector]; }
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:_target]; }
- (BOOL)respondsToSelector:(SEL)selector { return [_target respondsToSelector:selector]; }
- (BOOL)isKindOfClass:(Class)cls { return [_target isKindOfClass:cls]; }
- (BOOL)conformsToProtocol:(Protocol *)protocol { return [_target conformsToProtocol:protocol]; }
- (NSString *)description { return [_target description]; }
- (NSString *)debugDescription { return [_target debugDescription]; }
@end

static id (*orig_extensionWithIdentifier)(id, SEL, NSString *, NSError **);
static id hook_extensionWithIdentifier(id self, SEL _cmd, NSString *identifier, NSError **error) {
    id extension = orig_extensionWithIdentifier(self, _cmd, identifier, error);
    if (extension || ![identifier isKindOfClass:NSString.class]) return extension;

    NSString *appex = LCEFFindGuestAppex(identifier);
    if (!appex) {
        LOG(@"%@: not a system extension and no matching appex in %@ (contents: %@)", identifier,
            LCEFPlugInsPath(), [NSFileManager.defaultManager contentsOfDirectoryAtPath:LCEFPlugInsPath() error:nil]);
        return nil;
    }
    if (!gPayloadPath) gPayloadPath = LCEFPayloadPath(gSelfPath);
    if (!gPayloadPath) {
        LOG(@"%@: no copy of the dylib in the app group (app group %@), cannot forward", identifier, LCEFAppGroupPath());
        return nil;
    }
    NSString *liveProcess = LCEFLiveProcessIdentifier();
    if (!liveProcess) {
        LOG(@"%@: appex found, but no LiveProcess (install LiveContainer with \"Keep App Extensions\")", identifier);
        return nil;
    }
    extension = orig_extensionWithIdentifier(self, _cmd, liveProcess, error);
    if (!extension) {
        LOG(@"%@: the system has no extension %@ (error %@)", identifier, liveProcess, error ? *error : nil);
        return nil;
    }
    if (error) *error = nil;
    LOG(@"%@: forwarding %@ to %@", identifier, appex.lastPathComponent, liveProcess);
    return [[LCEFExtensionProxy alloc] initWithExtension:extension appex:appex];
}

__attribute__((constructor)) static void LCEFInstallHooks(void) {
#if LCEF_LOG
    // In the guest, HOME is the app's data container (visible in Files under LiveContainer).
    const char *home = getenv("HOME");
    gLogPath = [(home ? @(home) : NSHomeDirectory()) stringByAppendingPathComponent:@"Documents/LCExtForward.log"];
#endif
    gSelfPath = LCEFSelfPath();
    Class extensionClass = NSClassFromString(@"NSExtension");
    Method classMethod = class_getClassMethod(extensionClass, @selector(extensionWithIdentifier:error:));
    if (!classMethod) {
        LOG(@"+[NSExtension extensionWithIdentifier:error:] not found, not hooking");
        return;
    }
    orig_extensionWithIdentifier = (void *)method_setImplementation(classMethod, (IMP)hook_extensionWithIdentifier);
    LOG(@"loaded in %@ (%@) from %@, plugins: %@", NSBundle.mainBundle.bundleIdentifier, LCEFGuestAppPath().lastPathComponent,
        gSelfPath, [NSFileManager.defaultManager contentsOfDirectoryAtPath:LCEFPlugInsPath() error:nil]);
}

#pragma mark - LiveProcess side

static NSBundle *gAppexBundle;
static id gPrincipalObject;
static NSBundle *hook_mainBundle(id self, SEL _cmd) { return gAppexBundle; }

__attribute__((visibility("default")))
int LCExtForwardMain(int argc, char **argv, char **envp, char **apple) {
    Class handler = NSClassFromString(@"LiveProcessHandler");
    NSExtensionContext *context = [(Class<LCEFLiveProcessHandler>)handler extensionContext];
    NSDictionary *appInfo = [(Class<LCEFLiveProcessHandler>)handler retrievedAppInfo];

    // Sandbox access to the guest app and its data container comes first: the
    // appex and the log live there.
    static NSMutableArray<NSURL *> *accessed;
    accessed = [NSMutableArray array];
    NSMutableArray<NSString *> *failed = [NSMutableArray array];
    NSArray *bookmarks = appInfo[kBookmarksKey];
    for (NSData *data in [bookmarks isKindOfClass:NSArray.class] ? bookmarks : @[]) {
        BOOL stale = NO;
        NSError *error = nil;
        NSURL *url = [NSURL URLByResolvingBookmarkData:data options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:&error];
        if (url && [url startAccessingSecurityScopedResource]) [accessed addObject:url];
        else [failed addObject:url.path ?: error.localizedDescription ?: @"?"];
    }

#if LCEF_LOG
    if ([appInfo[kLogPathKey] isKindOfClass:NSString.class]) gLogPath = appInfo[kLogPathKey];
#endif
    NSString *appexPath = appInfo[kAppexPathKey];
    (void)accessed;   // held to keep the security-scoped access alive; count only logged
    (void)failed;     // diagnostics only
    LOG(@"LiveProcess payload started for %@ (access to %lu folders%@)", appexPath.lastPathComponent,
        (unsigned long)accessed.count, failed.count ? [NSString stringWithFormat:@", failed: %@", failed] : @"");
    NSBundle *appex = appexPath ? [NSBundle bundleWithPath:appexPath] : nil;
    if (!context || !appex.executablePath) {
        LOG(@"no context or appex (%@)", appexPath);
        return 1;
    }

    // The appex's code, including its constructors, sees itself as the main bundle.
    gAppexBundle = appex;
    method_setImplementation(class_getClassMethod(NSBundle.class, @selector(mainBundle)), (IMP)hook_mainBundle);

    if (!dlopen(appex.executablePath.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL)) {
        LOG(@"dlopen %@ failed: %s (patch_appex.py run on the IPA? appex signed by LiveContainer?)",
            appex.executablePath.lastPathComponent, dlerror());
        return 1;
    }
    NSDictionary *extensionInfo = appex.infoDictionary[@"NSExtension"];
    NSString *principalName = extensionInfo[@"NSExtensionPrincipalClass"];
    Class principal = principalName ? NSClassFromString(principalName) : Nil;
    if (!principal) {
        LOG(@"principal class %@ not found (storyboard extensions are not supported)", principalName);
        return 1;
    }
    id object = [principal new];
    if (![object respondsToSelector:@selector(beginRequestWithExtensionContext:)]) {
        LOG(@"%@ does not handle extension requests", principalName);
        return 1;
    }
    gPrincipalObject = object;   // NSExtensionMain keeps its principal object alive too
    LOG(@"running %@ (%@)", appex.bundleIdentifier, principalName);
    [(id<NSExtensionRequestHandling>)object beginRequestWithExtensionContext:context];
    CFRunLoopRun();
    return 0;
}
