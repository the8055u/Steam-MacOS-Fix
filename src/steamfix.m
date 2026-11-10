// steamfix — loaded into the Steam client via DYLD_INSERT_LIBRARIES (see launcher.sh).
// Steam's own files are never modified.
//
// Steam on macOS is two apps: steam_osx (Dock icon + menu bar, no real windows) and
// "Steam Helper" (an LSUIElement process that owns every visible window). macOS therefore
// sees Steam's windows as borderless windows of a background agent: square corners, and
// Stage Manager refuses to manage them.
//
// What this library does, per process:
//   steam_osx             - keeps DYLD_INSERT_LIBRARIES away from everything it spawns except
//                           the Steam Helper browser process (so games never load this library);
//                           serves its menu bar to the helper; steps back to a background app
//                           and stops fighting the helper for activation.
//   Steam Helper (browser) - gives Steam's windows the standard macOS window shape; becomes a
//                           regular app (so Stage Manager manages its windows) that shows
//                           steam_osx's menu bar by proxy and shares the Steam app's Dock tile.
//   anything else         - nothing.
//
// Environment (set by launcher.sh): STEAMFIX_DEBUG=1, STEAMFIX_SHAPE=0, STEAMFIX_STAGE=0, STEAMFIX_RENAME=0.

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <spawn.h>
#import <crt_externs.h>
#import <stdarg.h>
#import <sys/time.h>

typedef NS_ENUM(int, SFRole) { SFRoleNone = 0, SFRoleMain = 1, SFRoleHelper = 2 };

static SFRole gRole = SFRoleNone;
static char gSelfPath[PATH_MAX];
static BOOL gDebug = NO;
static BOOL gShape = YES;     // standard window shape
static BOOL gStage = YES;     // Stage Manager fix (helper becomes the app)
static pid_t gPeerPid = 0;    // main: helper pid (once it said hello); helper: steam_osx pid

#pragma mark - logging

static void sflog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void sflog(NSString *fmt, ...) {
    if (!gDebug) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static int fd = -1;
    if (fd < 0) {
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SteamFix.log"];
        fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) return;
    }
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    NSString *line = [NSString stringWithFormat:@"%02d:%02d:%02d.%03d [%d %s] %@\n", tm.tm_hour, tm.tm_min, tm.tm_sec,
                      (int)(tv.tv_usec / 1000), getpid(),
                      gRole == SFRoleMain ? "main" : gRole == SFRoleHelper ? "helper" : "-", msg];
    const char *c = line.UTF8String;
    write(fd, c, strlen(c));
}

static void swizzle(Class cls, SEL sel, IMP repl, IMP *orig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    if (!class_addMethod(cls, sel, repl, method_getTypeEncoding(m))) method_setImplementation(m, repl);
}

#pragma mark - environment hygiene (steam_osx)

static const char kInsertVar[] = "DYLD_INSERT_LIBRARIES";

static BOOL isHelperBrowserSpawn(const char *path, char *const argv[]) {
    if (!path) return NO;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    if (strcmp(base, "Steam Helper") != 0) return NO;
    if (argv) {
        for (int i = 1; argv[i]; i++) {
            if (strncmp(argv[i], "--type=", 7) == 0) return NO;   // renderer / gpu / utility
        }
    }
    return YES;
}

// Returns a malloc'd copy of envp with DYLD_INSERT_LIBRARIES=<this library> added.
static char **envWithInsert(char *const envp[]) {
    size_t n = 0;
    if (envp) while (envp[n]) n++;
    char **out = calloc(n + 2, sizeof(char *));
    size_t j = 0;
    size_t klen = strlen(kInsertVar);
    for (size_t i = 0; i < n; i++) {
        if (strncmp(envp[i], kInsertVar, klen) == 0 && envp[i][klen] == '=') continue;
        out[j++] = envp[i];
    }
    static char entry[PATH_MAX + 32];
    snprintf(entry, sizeof(entry), "%s=%s", kInsertVar, gSelfPath);
    out[j++] = entry;
    out[j] = NULL;
    return out;
}

static int sf_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
                          const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    if (gRole == SFRoleMain && isHelperBrowserSpawn(path, argv)) {
        char **env = envWithInsert(envp);
        int r = posix_spawn(pid, path, fa, attr, argv, env);
        free(env);
        return r;
    }
    return posix_spawn(pid, path, fa, attr, argv, envp);
}

static int sf_posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *fa,
                           const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    if (gRole == SFRoleMain && isHelperBrowserSpawn(file, argv)) {
        char **env = envWithInsert(envp);
        int r = posix_spawnp(pid, file, fa, attr, argv, env);
        free(env);
        return r;
    }
    return posix_spawnp(pid, file, fa, attr, argv, envp);
}

// steam_osx actually starts the helper with fork + exec; these run in the forked child.
static int sf_execve(const char *path, char *const argv[], char *const envp[]) {
    if (gRole == SFRoleMain && isHelperBrowserSpawn(path, argv)) return execve(path, argv, envWithInsert(envp));
    return execve(path, argv, envp);
}

static int sf_execv(const char *path, char *const argv[]) {
    if (gRole == SFRoleMain && isHelperBrowserSpawn(path, argv)) return execve(path, argv, envWithInsert(*_NSGetEnviron()));
    return execv(path, argv);
}

static int sf_execvp(const char *file, char *const argv[]) {
    if (gRole == SFRoleMain && isHelperBrowserSpawn(file, argv)) return execve(file, argv, envWithInsert(*_NSGetEnviron()));
    return execvp(file, argv);
}

#define SF_INTERPOSE(_replacement, _replacee)                                              \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
        _sf_interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = {       \
            (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee};

SF_INTERPOSE(sf_posix_spawn, posix_spawn)
SF_INTERPOSE(sf_posix_spawnp, posix_spawnp)
SF_INTERPOSE(sf_execve, execve)
SF_INTERPOSE(sf_execv, execv)
SF_INTERPOSE(sf_execvp, execvp)

#pragma mark - one Dock tile: the helper registers as the Steam app

// The Dock ties a running app to a tile by the bundle path the app registers with LaunchServices.
// Steam's windows belong to "Steam Helper.app", so as a regular app it would get a tile of its own
// next to the ordinary Steam icon (/Applications/Steam.app). When the helper registers, report the
// Steam app's path instead: the Dock then shows one tile, with Steam's own name and icon, and it
// is the same tile the user launches Steam from. Nothing inside the process changes — its main
// bundle, executable and code signature stay what they are.
static BOOL gRename = YES;
static BOOL gRegisteredAsSteamApp = NO;

static NSString *steamAppPath(void) {
    const char *env = getenv("STEAM_APP_BUNDLE_PATH");
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in @[env && *env ? @(env) : @"", @"/Applications/Steam.app"]) {
        if (p.length && [fm fileExistsAtPath:[p stringByAppendingPathComponent:@"Contents/Info.plist"]]) return p;
    }
    return nil;
}

extern CFDictionaryRef _LSApplicationCheckIn(int sessionID, CFDictionaryRef applicationInfo);

static CFDictionaryRef sf_LSApplicationCheckIn(int sessionID, CFDictionaryRef applicationInfo) {
    if (gRole == SFRoleHelper && gStage && gRename && applicationInfo) {
        NSString *app = steamAppPath();
        NSDictionary *info = (__bridge NSDictionary *)applicationInfo;
        if (app && info[@"LSBundlePath"]) {
            NSMutableDictionary *d = [info mutableCopy];
            d[@"LSBundlePath"] = app;
            d[@"CFBundleName"] = @"Steam";
            d[@"LSDisplayName"] = @"Steam";
            gRegisteredAsSteamApp = YES;
            sflog(@"registering with LaunchServices as %@", app);
            return _LSApplicationCheckIn(sessionID, (__bridge CFDictionaryRef)d);
        }
    }
    return _LSApplicationCheckIn(sessionID, applicationInfo);
}
SF_INTERPOSE(sf_LSApplicationCheckIn, _LSApplicationCheckIn)

#pragma mark - window shape (Steam Helper)

static const void *kAppliedKey = &kAppliedKey;
static BOOL gInApply = NO;
static const NSWindowStyleMask kShapeBits =
    NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView;

static BOOL isSDLWindow(NSWindow *w) { return [NSStringFromClass([w class]) hasPrefix:@"SDL"]; }

static NSString *describeWindow(NSWindow *w) {
    return [NSString stringWithFormat:@"<%@ %p '%@' mask=0x%lx level=%ld frame=%@ parent=%p vis=%d key=%d cb=0x%lx>",
            NSStringFromClass([w class]), w, w.title, (unsigned long)w.styleMask, (long)w.level,
            NSStringFromRect(w.frame), w.parentWindow, w.isVisible, w.isKeyWindow, (unsigned long)w.collectionBehavior];
}

// SDL_WindowFlags (SDL3)
enum : uint64_t { kSDLFullscreen = 0x1, kSDLUtility = 0x20000, kSDLTooltip = 0x40000, kSDLPopupMenu = 0x80000 };

// Reads the SDL window flags behind an SDL3Window, if we can find them.
static BOOL sdlWindowFlags(NSWindow *w, uint64_t *flags) {
    static uint64_t (*getFlags)(void *) = NULL;
    static Ivar ivar = NULL;
    static Class viewClass = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        getFlags = (uint64_t (*)(void *))dlsym(RTLD_DEFAULT, "SDL_GetWindowFlags");
        viewClass = NSClassFromString(@"SDL3View");
        if (viewClass) ivar = class_getInstanceVariable(viewClass, "_sdlWindow");
        sflog(@"SDL_GetWindowFlags=%p SDL3View._sdlWindow=%p", getFlags, ivar);
    });
    NSView *cv = w.contentView;
    if (!getFlags || !ivar || ![cv isKindOfClass:viewClass]) return NO;
    void *sdlwin = *(void **)((uint8_t *)(__bridge void *)cv + ivar_getOffset(ivar));
    if (!sdlwin) return NO;
    *flags = getFlags(sdlwin);
    return YES;
}

static BOOL windowQualifies(NSWindow *w) {
    if (!isSDLWindow(w)) return NO;                                        // only Steam's SDL windows
    if (w.parentWindow) return NO;                                         // popups attached to a parent
    if (w.styleMask & NSWindowStyleMaskFullScreen) return NO;
    uint64_t fl = 0;
    if (sdlWindowFlags(w, &fl)) {
        // Menus, dropdowns, tooltips and Big Picture keep their own shape.
        return (fl & (kSDLFullscreen | kSDLUtility | kSDLTooltip | kSDLPopupMenu)) == 0;
    }
    // Fallback when SDL internals are not reachable: untitled / small / raised windows are popups.
    if (w.level != NSNormalWindowLevel) return NO;
    if (w.title.length == 0) return NO;
    NSRect f = w.frame;
    if (f.size.width < 160 || f.size.height < 100) return NO;
    NSScreen *s = w.screen;
    if (s && f.size.width >= s.frame.size.width && f.size.height >= s.frame.size.height) return NO;
    return YES;
}

static void hideTitlebarChrome(NSWindow *w) {
    w.titlebarAppearsTransparent = YES;
    w.titleVisibility = NSWindowTitleHidden;
    w.tabbingMode = NSWindowTabbingModeDisallowed;
    NSView *container = nil;
    for (NSNumber *b in @[@(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton)]) {
        NSButton *btn = [w standardWindowButton:(NSWindowButton)b.integerValue];
        btn.hidden = YES;
        if (!container) container = btn.superview.superview;   // NSTitlebarContainerView
    }
    // Steam draws its own title bar; the (invisible) system one must not eat its clicks.
    if (container && [NSStringFromClass([container class]) containsString:@"Titlebar"]) container.hidden = YES;
}

static void applyShape(NSWindow *w, const char *why) {
    if (!gShape || gInApply || !windowQualifies(w)) return;
    NSWindowStyleMask have = w.styleMask;
    NSWindowStyleMask want = have | kShapeBits;
    if (have == want && objc_getAssociatedObject(w, kAppliedKey)) return;

    gInApply = YES;
    if (have != want) {
        // setStyleMask: rebuilds the frame view and disturbs the responder chain;
        // SDL relies on contentView.nextResponder being its listener.
        NSView *cv = w.contentView;
        NSResponder *next = cv.nextResponder;
        NSResponder *first = w.firstResponder;
        NSRect frame = w.frame;
        [w setStyleMask:want];
        if (cv.nextResponder != next) cv.nextResponder = next;
        if (first && first != w && w.firstResponder != first) [w makeFirstResponder:first];
        if (!NSEqualRects(w.frame, frame)) [w setFrame:frame display:YES];
    }
    hideTitlebarChrome(w);
    [w invalidateShadow];
    objc_setAssociatedObject(w, kAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gInApply = NO;
    sflog(@"shape (%s) %@", why, describeWindow(w));
}

// -[NSWindow setStyleMask:] — keep our bits when Steam/SDL re-asserts its borderless mask.
static IMP gOrigSetStyleMask;
static void sf_setStyleMask(NSWindow *self, SEL _cmd, NSWindowStyleMask mask) {
    if (!gInApply && objc_getAssociatedObject(self, kAppliedKey) && !(mask & NSWindowStyleMaskFullScreen)) {
        NSView *cv = self.contentView;
        NSResponder *next = cv.nextResponder;
        gInApply = YES;
        ((void (*)(id, SEL, NSWindowStyleMask))gOrigSetStyleMask)(self, _cmd, mask | kShapeBits);
        if (cv.nextResponder != next) cv.nextResponder = next;
        hideTitlebarChrome(self);
        gInApply = NO;
        return;
    }
    ((void (*)(id, SEL, NSWindowStyleMask))gOrigSetStyleMask)(self, _cmd, mask);
}

// -[NSWindow orderWindow:relativeTo:] — shape the window before it first appears.
static IMP gOrigOrderWindow;
static void sf_orderWindow(NSWindow *self, SEL _cmd, NSWindowOrderingMode mode, NSInteger other) {
    if (mode != NSWindowOut) applyShape(self, "order");
    ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))gOrigOrderWindow)(self, _cmd, mode, other);
}

// -[NSWindow setContentView:] — SDL installs its view right after creating the window.
static IMP gOrigSetContentView;
static void sf_setContentView(NSWindow *self, SEL _cmd, NSView *view) {
    ((void (*)(id, SEL, NSView *))gOrigSetContentView)(self, _cmd, view);
    if (view) applyShape(self, "contentView");
}

static void setupShape(void) {
    if (!gShape) return;
    swizzle([NSWindow class], @selector(setStyleMask:), (IMP)sf_setStyleMask, &gOrigSetStyleMask);
    swizzle([NSWindow class], @selector(orderWindow:relativeTo:), (IMP)sf_orderWindow, &gOrigOrderWindow);
    swizzle([NSWindow class], @selector(setContentView:), (IMP)sf_setContentView, &gOrigSetContentView);
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    for (NSNotificationName n in @[NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification,
                                   NSWindowDidUpdateNotification, NSWindowDidExitFullScreenNotification]) {
        [nc addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:[NSWindow class]]) applyShape(note.object, "notify");
        }];
    }
}

#pragma mark - IPC between helper and steam_osx

typedef NS_ENUM(SInt32, SFMsg) { SFMsgHello = 1, SFMsgGetMenu, SFMsgPerform, SFMsgReopen, SFMsgQuit, SFMsgURL };

static CFStringRef createPortName(pid_t mainPid) {
    return (__bridge_retained CFStringRef)[NSString stringWithFormat:@"local.steamfix.%d", mainPid];
}

// helper -> steam_osx. Returns YES if delivered; *reply is filled when a reply was asked for.
static BOOL sendToMain(SFMsg msg, NSData *payload, NSData **reply) {
    static CFMessagePortRef port = NULL;
    if (port && !CFMessagePortIsValid(port)) { CFRelease(port); port = NULL; }
    if (!port) {
        CFStringRef name = createPortName(gPeerPid);
        port = CFMessagePortCreateRemote(NULL, name);
        CFRelease(name);
        if (!port) return NO;
    }
    CFDataRef out = NULL;
    SInt32 r = CFMessagePortSendRequest(port, msg, (__bridge CFDataRef)(payload ?: [NSData data]), 0.3, 0.3,
                                        reply ? CFSTR("local.steamfix.reply") : NULL, reply ? &out : NULL);
    if (r != kCFMessagePortSuccess) { sflog(@"ipc msg %d failed: %d", (int)msg, (int)r); return NO; }
    if (reply) *reply = out ? CFBridgingRelease(out) : nil;
    return YES;
}

#pragma mark - menu bar: served by steam_osx

static NSDictionary *serializeItem(NSMenuItem *it, int depth) {
    if (it.isSeparatorItem) return @{@"sep": @YES};
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"t"] = it.title ?: @"";
    d[@"en"] = @(it.isEnabled);
    d[@"st"] = @(it.state);
    d[@"hid"] = @(it.isHidden);
    d[@"key"] = it.keyEquivalent ?: @"";
    d[@"mod"] = @(it.keyEquivalentModifierMask);
    d[@"act"] = it.action ? NSStringFromSelector(it.action) : @"";
    if (it.hasSubmenu && depth < 4) {
        NSMenu *sub = it.submenu;
        if (sub == [NSApp servicesMenu]) {
            d[@"services"] = @YES;
        } else {
            id<NSMenuDelegate> del = sub.delegate;
            if ([del respondsToSelector:@selector(menuNeedsUpdate:)]) [del menuNeedsUpdate:sub];
            [sub update];
            NSMutableArray *items = [NSMutableArray array];
            for (NSMenuItem *c in sub.itemArray) [items addObject:serializeItem(c, depth + 1)];
            d[@"sub"] = items;
        }
    }
    return d;
}

static NSData *serializedMainMenu(void) {
    NSMutableArray *top = [NSMutableArray array];
    for (NSMenuItem *it in [NSApp mainMenu].itemArray) [top addObject:serializeItem(it, 0)];
    return [NSPropertyListSerialization dataWithPropertyList:top format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
}

static void performMenuPath(NSDictionary *req) {
    NSArray<NSNumber *> *path = req[@"path"];
    NSString *title = req[@"t"];
    if (!path.count || !title) return;
    NSMenu *menu = [NSApp mainMenu];
    for (NSUInteger i = 0; i + 1 < path.count; i++) {
        NSInteger idx = path[i].integerValue;
        if (idx < 0 || idx >= menu.numberOfItems) return;
        menu = [menu itemAtIndex:idx].submenu;
        if (!menu) return;
    }
    NSInteger idx = path.lastObject.integerValue;
    if (idx < 0 || idx >= menu.numberOfItems || ![[menu itemAtIndex:idx].title isEqualToString:title]) {
        idx = [menu indexOfItemWithTitle:title];   // the menu changed since the helper last looked
        if (idx < 0) { sflog(@"menu item '%@' not found", title); return; }
    }
    sflog(@"perform '%@'", title);
    [menu performActionForItemAtIndex:idx];
}

static void mainStepBack(void) {
    if (!gStage) return;
    // The helper is the visible app now; steam_osx keeps running without a Dock tile.
    if ([NSApp activationPolicy] == NSApplicationActivationPolicyRegular) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        sflog(@"steam_osx -> accessory");
    }
}

static CFDataRef mainPortCallback(CFMessagePortRef local, SInt32 msgid, CFDataRef data, void *info) {
    @autoreleasepool {
        NSData *payload = data ? [NSData dataWithData:(__bridge NSData *)data] : nil;
        switch (msgid) {
            case SFMsgHello: {
                int32_t pid = 0;
                if (payload.length >= sizeof(pid)) [payload getBytes:&pid length:sizeof(pid)];
                gPeerPid = pid;
                sflog(@"hello from helper %d", pid);
                dispatch_async(dispatch_get_main_queue(), ^{ mainStepBack(); });
                return NULL;
            }
            case SFMsgGetMenu: {
                NSData *d = serializedMainMenu();
                return d ? (CFDataRef)CFBridgingRetain(d) : NULL;
            }
            case SFMsgPerform: {
                NSDictionary *req = payload.length ? [NSPropertyListSerialization propertyListWithData:payload options:0 format:NULL error:NULL] : nil;
                if ([req isKindOfClass:[NSDictionary class]]) dispatch_async(dispatch_get_main_queue(), ^{ performMenuPath(req); });
                return NULL;
            }
            case SFMsgReopen: {
                dispatch_async(dispatch_get_main_queue(), ^{
                    id del = [NSApp delegate];
                    BOOL can = [del respondsToSelector:@selector(applicationShouldHandleReopen:hasVisibleWindows:)];
                    sflog(@"reopen (delegate %@ handles=%d)", NSStringFromClass([del class]), can);
                    if (can) [del applicationShouldHandleReopen:NSApp hasVisibleWindows:NO];
                });
                return NULL;
            }
            case SFMsgQuit:
                dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
                return NULL;
            case SFMsgURL: {
                // A steam:// link that the system delivered to the helper. Hand it to steam_osx the
                // way the system would have: as a "get URL" Apple event addressed to this process.
                NSString *url = payload.length ? [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] : nil;
                if (url.length) dispatch_async(dispatch_get_main_queue(), ^{
                    NSAppleEventDescriptor *ev =
                        [NSAppleEventDescriptor appleEventWithEventClass:kInternetEventClass eventID:kAEGetURL
                                                        targetDescriptor:[NSAppleEventDescriptor currentProcessDescriptor]
                                                                returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
                    [ev setParamDescriptor:[NSAppleEventDescriptor descriptorWithString:url] forKeyword:keyDirectObject];
                    NSError *err = nil;
                    [ev sendEventWithOptions:NSAppleEventSendNoReply timeout:5 error:&err];
                    sflog(@"url %@ -> %@", url, err ? err.localizedDescription : @"delivered");
                });
                return NULL;
            }
        }
    }
    return NULL;
}

// steam_osx re-activates itself whenever the helper comes to the front (so that its menu bar
// shows while the background helper has focus). With the helper as a regular app that turns
// into an endless tug-of-war, so that one reaction is dropped.
static IMP gOrigActivateIgnoring;
static void sf_activateIgnoring(id self, SEL _cmd, BOOL flag) {
    if (gPeerPid > 0 && [NSWorkspace sharedWorkspace].frontmostApplication.processIdentifier == gPeerPid) {
        sflog(@"dropped activateIgnoringOtherApps (helper is frontmost)");
        return;
    }
    ((void (*)(id, SEL, BOOL))gOrigActivateIgnoring)(self, _cmd, flag);
}

// Once the helper is the app, steam_osx must not grow a second Dock tile again. It turns itself
// back into a foreground app when it is activated (e.g. by clicking the stock Steam icon).
static IMP gOrigSetPolicy;
static BOOL sf_setActivationPolicy(id self, SEL _cmd, NSApplicationActivationPolicy policy) {
    if (gPeerPid > 0 && policy == NSApplicationActivationPolicyRegular) {
        sflog(@"kept steam_osx in the background (setActivationPolicy)");
        return YES;
    }
    return ((BOOL (*)(id, SEL, NSApplicationActivationPolicy))gOrigSetPolicy)(self, _cmd, policy);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus sf_TransformProcessType(const ProcessSerialNumber *psn, ProcessApplicationTransformState type) {
    if (gRole == SFRoleMain && gStage && gPeerPid > 0 && type == kProcessTransformToForegroundApplication) {
        sflog(@"kept steam_osx in the background (TransformProcessType)");
        return noErr;
    }
    return TransformProcessType(psn, type);
}
SF_INTERPOSE(sf_TransformProcessType, TransformProcessType)
#pragma clang diagnostic pop

static void setupMain(void) {
    if (!gStage) return;
    // steam_osx has no windows of its own; the helper is the app the user sees. Start it as a
    // background app right away so no second Dock tile flashes up during launch...
    @try {
        NSMutableDictionary *info = (__bridge NSMutableDictionary *)CFBundleGetInfoDictionary(CFBundleGetMainBundle());
        if ([info respondsToSelector:@selector(setObject:forKey:)]) info[@"LSUIElement"] = @YES;
    } @catch (id e) {}
    // ...but if no helper shows up, give Steam its Dock icon back.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (gPeerPid <= 0 && [NSApp activationPolicy] != NSApplicationActivationPolicyRegular) {
            sflog(@"no helper reported in; steam_osx -> regular app");
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        }
    });
    swizzle([NSApplication class], @selector(activateIgnoringOtherApps:), (IMP)sf_activateIgnoring, &gOrigActivateIgnoring);
    swizzle([NSApplication class], @selector(setActivationPolicy:), (IMP)sf_setActivationPolicy, &gOrigSetPolicy);
    // Safety net in case the policy is changed by some other route.
    for (NSNotificationName n in @[NSApplicationDidBecomeActiveNotification, NSApplicationDidResignActiveNotification]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) {
            if (gPeerPid > 0) mainStepBack();
        }];
    }
    CFStringRef name = createPortName(getpid());
    CFMessagePortRef port = CFMessagePortCreateLocal(NULL, name, mainPortCallback, NULL, NULL);
    CFRelease(name);
    if (!port) { sflog(@"could not create port"); return; }
    CFRunLoopSourceRef src = CFMessagePortCreateRunLoopSource(NULL, port, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
}

#pragma mark - menu bar: shown by the helper

@interface SFMenuProxy : NSObject <NSMenuDelegate>
@end

static SFMenuProxy *gProxy;
static NSData *gLastMenuData;

static NSArray *fetchMenuTree(NSData **raw) {
    NSData *d = nil;
    if (!sendToMain(SFMsgGetMenu, nil, &d) || !d.length) return nil;
    NSArray *tree = [NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:NULL];
    if (![tree isKindOfClass:[NSArray class]] || tree.count == 0) return nil;
    if (raw) *raw = d;
    return tree;
}

static void populateMenu(NSMenu *menu, NSArray<NSDictionary *> *items, NSArray<NSNumber *> *prefix) {
    [menu removeAllItems];
    menu.autoenablesItems = NO;
    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *d = items[i];
        if ([d[@"sep"] boolValue]) { [menu addItem:[NSMenuItem separatorItem]]; continue; }
        NSString *title = d[@"t"] ?: @"";
        NSString *act = d[@"act"] ?: @"";
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:d[@"key"] ?: @""];
        it.keyEquivalentModifierMask = [d[@"mod"] unsignedIntegerValue];
        it.state = [d[@"st"] integerValue];
        it.hidden = [d[@"hid"] boolValue];
        it.enabled = [d[@"en"] boolValue];
        NSArray *path = [prefix arrayByAddingObject:@(i)];
        if ([d[@"services"] boolValue]) {
            NSMenu *sv = [[NSMenu alloc] initWithTitle:title];
            it.submenu = sv;
            [NSApp setServicesMenu:sv];
        } else if (d[@"sub"]) {
            NSMenu *sub = [[NSMenu alloc] initWithTitle:title];
            populateMenu(sub, d[@"sub"], path);
            it.submenu = sub;
        } else if ([act isEqualToString:@"hide:"] || [act isEqualToString:@"hideOtherApplications:"] ||
                   [act isEqualToString:@"unhideAllApplications:"]) {
            // These must act on the app that owns the windows, i.e. this one.
            it.target = NSApp;
            it.action = NSSelectorFromString(act);
            it.enabled = YES;
        } else {
            it.target = gProxy;
            it.action = @selector(proxyAction:);
            it.representedObject = @{@"path": path, @"t": title};
        }
        [menu addItem:it];
    }
}

static void installMenu(NSArray<NSDictionary *> *tree) {
    NSMenu *mm = [[NSMenu alloc] initWithTitle:@"MainMenu"];
    for (NSUInteger i = 0; i < tree.count; i++) {
        NSDictionary *d = tree[i];
        NSString *title = d[@"t"] ?: @"";
        NSMenuItem *top = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
        NSMenu *sub = [[NSMenu alloc] initWithTitle:title];
        sub.delegate = gProxy;
        populateMenu(sub, d[@"sub"] ?: @[], @[@(i)]);
        top.submenu = sub;
        [mm addItem:top];
    }
    [NSApp setMainMenu:mm];
    sflog(@"menu installed (%lu top-level items)", (unsigned long)tree.count);
}

// Pulls the menu from steam_osx and installs it if it changed. Returns NO if steam_osx had none yet.
static BOOL refreshMenu(void) {
    NSData *raw = nil;
    NSArray *tree = fetchMenuTree(&raw);
    if (!tree) return NO;
    if (![raw isEqualToData:gLastMenuData] || [NSApp mainMenu].numberOfItems != (NSInteger)tree.count) {
        gLastMenuData = raw;
        installMenu(tree);
    }
    return YES;
}

@implementation SFMenuProxy

- (void)proxyAction:(NSMenuItem *)sender {
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:sender.representedObject
                                                           format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    sendToMain(SFMsgPerform, d, NULL);
}

// A top-level menu is about to open: show steam_osx's current state (checkmarks, counts, ...).
- (void)menuNeedsUpdate:(NSMenu *)menu {
    NSInteger idx = [[NSApp mainMenu] indexOfItemWithSubmenu:menu];
    if (idx < 0) return;
    NSData *raw = nil;
    NSArray *tree = fetchMenuTree(&raw);
    if (!tree || idx >= (NSInteger)tree.count) return;
    gLastMenuData = raw;
    populateMenu(menu, tree[idx][@"sub"] ?: @[], @[@(idx)]);
}

- (void)handleReopen:(NSAppleEventDescriptor *)event withReply:(NSAppleEventDescriptor *)reply {
    BOOL anyVisible = NO;
    for (NSWindow *w in [NSApp windows]) {
        if (w.isVisible && isSDLWindow(w) && !w.parentWindow && w.frame.size.width > 100) { anyVisible = YES; break; }
    }
    sflog(@"reopen event, visible windows=%d", anyVisible);
    if (!anyVisible) sendToMain(SFMsgReopen, nil, NULL);
}

- (void)handleQuit:(NSAppleEventDescriptor *)event withReply:(NSAppleEventDescriptor *)reply {
    sflog(@"quit event -> steam_osx");
    sendToMain(SFMsgQuit, nil, NULL);
}

- (void)handleURL:(NSAppleEventDescriptor *)event withReply:(NSAppleEventDescriptor *)reply {
    NSString *url = [event paramDescriptorForKeyword:keyDirectObject].stringValue;
    sflog(@"url event %@ -> steam_osx", url);
    if (url.length) sendToMain(SFMsgURL, [url dataUsingEncoding:NSUTF8StringEncoding], NULL);
}

@end

#pragma mark - helper becomes the app (Stage Manager)

// Name shown in the Dock, app switcher and menu bar. Same LaunchServices call Chromium uses to
// name its helper processes.
static void setDisplayName(NSString *name) {
    CFTypeRef (*getASN)(void) = dlsym(RTLD_DEFAULT, "_LSGetCurrentApplicationASN");
    OSStatus (*setItem)(int, CFTypeRef, CFStringRef, CFStringRef, CFDictionaryRef *) =
        dlsym(RTLD_DEFAULT, "_LSSetApplicationInformationItem");
    CFStringRef *key = dlsym(RTLD_DEFAULT, "_kLSDisplayNameKey");
    if (!getASN || !setItem || !key || !*key) { sflog(@"display-name API unavailable"); return; }
    CFTypeRef asn = getASN();
    if (!asn) return;
    OSStatus st = setItem(-2 /* kLSDefaultSessionID */, asn, *key, (__bridge CFStringRef)name, NULL);
    sflog(@"display name -> %@ (%d)", name, (int)st);
}

static void setSteamIcon(void) {
    // The helper bundle ships no icon of its own. Ask the system for the Steam app's icon: that is
    // the current full-bleed one from its asset catalog, already rendered in the system icon shape
    // (the bundled Steam.icns is the old round artwork).
    NSFileManager *fm = [NSFileManager defaultManager];
    const char *env = getenv("STEAM_APP_BUNDLE_PATH");
    NSMutableArray<NSString *> *apps = [NSMutableArray array];
    if (env && *env) [apps addObject:@(env)];
    [apps addObject:@"/Applications/Steam.app"];
    for (NSString *app in apps) {
        if (![fm fileExistsAtPath:app]) continue;
        NSImage *img = [[NSWorkspace sharedWorkspace] iconForFile:app];
        if (img) { img.size = NSMakeSize(512, 512); [NSApp setApplicationIconImage:img]; sflog(@"icon from %@", app); return; }
    }
    // Fallback: .../Steam/Contents/MacOS/Steam.icns next to steam_osx.
    NSString *dir = [NSBundle mainBundle].executablePath;
    for (int i = 0; i < 5; i++) dir = dir.stringByDeletingLastPathComponent;
    NSImage *img = [[NSImage alloc] initWithContentsOfFile:[dir stringByAppendingPathComponent:@"Steam.icns"]];
    if (img) [NSApp setApplicationIconImage:img];
}

static void helperBecomeApp(void) {
    if (!gStage || gPeerPid <= 0) return;
    gProxy = [SFMenuProxy new];

    BOOL ok = [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    sflog(@"helper -> regular app (%d)", ok);
    if (!gRegisteredAsSteamApp) {
        // Not sharing the Steam app's Dock tile: at least give this app Steam's name and icon.
        setDisplayName(@"Steam");
        setSteamIcon();
    }

    int32_t pid = getpid();
    sendToMain(SFMsgHello, [NSData dataWithBytes:&pid length:sizeof(pid)], NULL);

    // Clicks on the Dock icon, Quit and steam:// links are addressed to this app now; steam_osx is
    // the one that knows what to do with them. SDL installs handlers of its own while the app
    // finishes launching, so claim these again a little later.
    void (^installHandlers)(void) = ^{
        NSAppleEventManager *aem = [NSAppleEventManager sharedAppleEventManager];
        [aem setEventHandler:gProxy andSelector:@selector(handleReopen:withReply:)
               forEventClass:kCoreEventClass andEventID:kAEReopenApplication];
        [aem setEventHandler:gProxy andSelector:@selector(handleQuit:withReply:)
               forEventClass:kCoreEventClass andEventID:kAEQuitApplication];
        [aem setEventHandler:gProxy andSelector:@selector(handleURL:withReply:)
               forEventClass:kInternetEventClass andEventID:kAEGetURL];
    };
    installHandlers();
    for (NSNumber *delay in @[@0.5, @3.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), installHandlers);
    }

    // steam_osx builds its menu in stages (before / after sign-in), so follow it closely for the
    // first couple of minutes; after that, activation and opening a menu keep it current.
    refreshMenu();
    __block int ticks = 0;
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        refreshMenu();
        if (++ticks >= 120) [t invalidate];
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification *n) { refreshMenu(); }];
}

static void setupHelper(void) {
    setupShape();
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
        sflog(@"didFinishLaunching policy=%ld", (long)[NSApp activationPolicy]);
        for (NSWindow *w in [NSApp windows]) applyShape(w, "launch");
        helperBecomeApp();
    }];
}

#pragma mark - debug channel (STEAMFIX_DEBUG only)

static void describeMenu(NSMenu *m, int depth, NSMutableString *out) {
    for (NSMenuItem *it in m.itemArray) {
        if (it.isSeparatorItem) continue;
        [out appendFormat:@"%*s%@%@\n", depth * 2 + 6, "", it.title, it.hasSubmenu ? @" >" : @""];
        if (it.hasSubmenu && depth < 1) describeMenu(it.submenu, depth + 1, out);
    }
}

static void handleCommand(NSString *cmd) {
    NSString *prefix = gRole == SFRoleMain ? @"main:" : @"helper:";
    if (![cmd hasPrefix:prefix]) return;
    NSArray<NSString *> *a = [[cmd substringFromIndex:prefix.length] componentsSeparatedByString:@" "];
    NSString *op = a.firstObject;
    sflog(@"cmd %@", cmd);
    if ([op isEqualToString:@"dump"]) {
        NSMutableString *menu = [NSMutableString string];
        describeMenu([NSApp mainMenu], 0, menu);
        id del = [NSApp delegate];
        sflog(@"policy=%ld active=%d peer=%d delegate=%@ reopen=%d menu:\n%@", (long)[NSApp activationPolicy], [NSApp isActive], gPeerPid,
              NSStringFromClass([del class]), [del respondsToSelector:@selector(applicationShouldHandleReopen:hasVisibleWindows:)], menu);
        for (NSWindow *w in [NSApp windows]) {
            uint64_t fl = 0;
            BOOL known = sdlWindowFlags(w, &fl);
            sflog(@"window %@ sdl=%s0x%llx", describeWindow(w), known ? "" : "?", fl);
        }
    } else if ([op isEqualToString:@"policy"] && a.count > 1) {
        [NSApp setActivationPolicy:(NSApplicationActivationPolicy)a[1].integerValue];
    } else if ([op isEqualToString:@"menu"] && a.count > 2) {
        // helper:menu <top index> <item index> — trigger a proxied item as if it was clicked
        NSMenu *sub = [[NSApp mainMenu] itemAtIndex:a[1].integerValue].submenu;
        [gProxy menuNeedsUpdate:sub];
        NSInteger i = a[2].integerValue;
        if (i >= 0 && i < sub.numberOfItems) [sub performActionForItemAtIndex:i];
    }
}

static void setupDebugChannel(void) {
    if (!gDebug) return;
    [[NSDistributedNotificationCenter defaultCenter] addObserverForName:@"local.steamfix.cmd" object:nil
                                                                  queue:[NSOperationQueue mainQueue]
                                                             usingBlock:^(NSNotification *note) {
        if ([note.object isKindOfClass:[NSString class]]) handleCommand(note.object);
    }];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { sflog(@"didBecomeActive"); }];
    [nc addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { sflog(@"didResignActive"); }];
}

#pragma mark - entry

static BOOL envFlag(const char *name, BOOL dflt) {
    const char *v = getenv(name);
    if (!v || !*v) return dflt;
    return !(v[0] == '0' || v[0] == 'n' || v[0] == 'N');
}

__attribute__((constructor)) static void steamfix_init(void) {
    Dl_info info;
    if (dladdr((const void *)&steamfix_init, &info) && info.dli_fname) {
        if (!realpath(info.dli_fname, gSelfPath)) strlcpy(gSelfPath, info.dli_fname, sizeof(gSelfPath));
    }
    gDebug = envFlag("STEAMFIX_DEBUG", NO);
    gShape = envFlag("STEAMFIX_SHAPE", YES);
    gStage = envFlag("STEAMFIX_STAGE", YES);
    gRename = envFlag("STEAMFIX_RENAME", YES);

    char ***argvp = _NSGetArgv();
    int argc = *_NSGetArgc();
    char **argv = argvp ? *argvp : NULL;
    const char *exe = (argv && argc > 0 && argv[0]) ? argv[0] : "";
    const char *base = strrchr(exe, '/');
    base = base ? base + 1 : exe;

    if (strcmp(base, "steam_osx") == 0) {
        gRole = SFRoleMain;
    } else if (strcmp(base, "Steam Helper") == 0) {
        gRole = SFRoleHelper;
        for (int i = 1; i < argc; i++) {
            if (!argv[i]) continue;
            if (strncmp(argv[i], "--type=", 7) == 0) { gRole = SFRoleNone; break; }
            if (strncmp(argv[i], "-steampid=", 10) == 0) gPeerPid = atoi(argv[i] + 10);
        }
        if (gRole == SFRoleHelper && gPeerPid <= 0) gPeerPid = getppid();
    }

    // Nothing spawned from here on inherits the library unless sf_posix_spawn & co. add it back.
    unsetenv(kInsertVar);

    sflog(@"loaded into %s shape=%d stage=%d bundle=%@", base, gShape, gStage, [NSBundle mainBundle].bundlePath.lastPathComponent);
    if (gRole == SFRoleMain) setupMain();
    if (gRole == SFRoleHelper) setupHelper();
    if (gRole != SFRoleNone) setupDebugChannel();
}
