// Experimental native host. Requires Adobe's SDK headers; no Adobe code is bundled.
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "PIFormat.h"
#include "PIProperties.h"
#include "../Native/CameraRawHost/MemorySuites.hpp"

static SPBasicSuite basic;
static int missingSuites = 0;
static uint32_t apiVersion = 0;
static bool publicServices = false;
static NSString *captureDirectory = nil;
static NSString *automation = @"none";

struct PluginResources {
    CFBundleRef bundle = nullptr;
    CFBundleRefNum map = -1;
    ResFileRefNum previous = CurResFile();
    bool open(NSURL *url) {
        bundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)url);
        if (!bundle) return false;
        map = CFBundleOpenBundleResourceMap(bundle);
        if (map == -1) return false;
        UseResFile(map);
        fprintf(stderr, "Resource map: ref=%d PiPL=%d DLOG=%d STR#=%d\n", int(map),
                int(Count1Resources('PiPL')), int(Count1Resources('DLOG')), int(Count1Resources('STR#')));
        return true;
    }
    ~PluginResources() {
        if (map != -1) { UseResFile(previous); CFBundleCloseBundleResourceMap(bundle, map); }
        if (bundle) CFRelease(bundle);
    }
};

static void describeHierarchy(NSView *view, unsigned depth, unsigned *remaining) {
    if (!view || view.isHiddenOrHasHiddenAncestor || !*remaining || depth > 8) return;
    --*remaining;
    fprintf(stderr, "View depth=%u class=%s frame=%s\n", depth,
            NSStringFromClass(view.class).UTF8String, NSStringFromRect(view.frame).UTF8String);
    if ([view isKindOfClass:[NSControl class]]) {
        NSControl *control = (NSControl *)view;
        fprintf(stderr, "Control tag=%ld enabled=%d target=%s label=%s help=%s tooltip=%s identifier=%s action=%s\n",
                long(control.tag), int(control.enabled), NSStringFromClass([control.target class]).UTF8String,
                control.accessibilityLabel.UTF8String,
                control.accessibilityHelp.UTF8String, control.toolTip.UTF8String,
                control.identifier.UTF8String,
                control.action ? NSStringFromSelector(control.action).UTF8String : "");
        if ([view isKindOfClass:[NSButton class]])
            fprintf(stderr, "Button: %s\n", [(NSButton *)view title].UTF8String);
    }
    for (NSView *child in view.subviews) describeHierarchy(child, depth + 1, remaining);
}

static void describeOwnedWindows() {
    for (NSWindow *window in NSApp.windows) {
        fprintf(stderr, "Owned window title=%s visible=%d class=%s frame=%s\n",
                window.title.UTF8String, int(window.visible), NSStringFromClass(window.class).UTF8String,
                NSStringFromRect(window.frame).UTF8String);
        unsigned remaining = 80;
        describeHierarchy(window.contentView, 0, &remaining);
    }
}

static void traceCaller(void *caller) {
    Dl_info info{};
    if (dladdr(caller, &info) && info.dli_fbase) {
        fprintf(stderr, "Callback caller offset=0x%llx\n",
                (unsigned long long)((uintptr_t)caller - (uintptr_t)info.dli_fbase));
    }
}

static OSErr getProperty(PIType signature, PIType key, int32 index,
                         intptr_t *simple, Handle *complex) {
    char code[] = {char(key >> 24), char(key >> 16), char(key >> 8), char(key), 0};
    fprintf(stderr, "GetProperty: signature=%08x key=%s index=%d\n",
            unsigned(signature), code, int(index));
    traceCaller(__builtin_return_address(0));
    if (simple) *simple = 0;
    if (complex) *complex = nullptr;
    if (key == propVersion && simple && apiVersion) {
        *simple = apiVersion;
        return noErr;
    }
    // Serial/license properties remain undefined in every diagnostic profile.
    return errPlugInPropertyUndefined;
}

static OSErr setProperty(PIType, PIType, int32, intptr_t, Handle) {
    return errPlugInPropertyUndefined;
}

static PropertyProcs properties = {kCurrentPropertyProcsVersion,
    kCurrentPropertyProcsCount, getProperty, setProperty};

static SPErr acquireSuite(const char *name, int32 version, const void **suite) {
    fprintf(stderr, "AcquireSuite: %s v%d\n", name ? name : "(null)", int(version));
    traceCaller(__builtin_return_address(0));
    if (!suite) return kSPBadParameterError;
    *suite = nullptr;
    if (name && strcmp(name, kSPBasicSuite) == 0 && version == kSPBasicSuiteVersion) {
        *suite = &basic;
        return kSPNoError;
    }
    if (name && strcmp(name, kPIPropertySuite) == 0 && version == kPIPropertySuiteVersion) {
        *suite = &properties;
        return kSPNoError;
    }
    if (name && publicServices && (*suite = ProbeMemory::suite(name, version))) return kSPNoError;
    ++missingSuites;
    return kSPSuiteNotFoundError;
}

static SPErr releaseSuite(const char *name, int32 version) {
    fprintf(stderr, "ReleaseSuite: %s v%d\n", name ? name : "(null)", int(version));
    bool known = name && ((strcmp(name, kSPBasicSuite) == 0 && version == kSPBasicSuiteVersion)
        || (strcmp(name, kPIPropertySuite) == 0 && version == kPIPropertySuiteVersion)
        || (publicServices && ProbeMemory::suite(name, version)));
    return known ? kSPNoError : kSPSuiteNotFoundError;
}

static SPBoolean equalTokens(const char *a, const char *b) {
    return a && b && strcmp(a, b) == 0;
}

static SPErr allocateBlock(size_t size, void **block) {
    if (!block) return kSPBadParameterError;
    *block = malloc(size ? size : 1);
    return *block ? kSPNoError : kSPOutOfMemoryError;
}

static SPErr freeBlock(void *block) { free(block); return kSPNoError; }

static SPErr reallocateBlock(void *block, size_t size, void **replacement) {
    if (!replacement) return kSPBadParameterError;
    *replacement = realloc(block, size ? size : 1);
    return *replacement ? kSPNoError : kSPOutOfMemoryError;
}

static SPErr undefinedFunction() { return kSPUnimplementedError; }
static Boolean abortOperation() { return false; }
static OSErr advanceState() {
    fprintf(stderr, "AdvanceState requested; pixel transfer is not implemented in this probe.\n");
    return errPlugInHostInsufficient;
}
static void reportProgress(int32 done, int32 total) {
    fprintf(stderr, "Progress: %d/%d\n", int(done), int(total));
}

static bool describeView(NSView *view) {
    bool unsupported = false;
    if ([view isKindOfClass:[NSTextField class]]) {
        NSString *text = [(NSTextField *)view stringValue];
        fprintf(stderr, "Window text: %s\n", text.UTF8String);
        unsupported = [text isEqualToString:@"It is not compatible with this host."];
    }
    for (NSView *child in view.subviews) unsupported = describeView(child) || unsupported;
    return unsupported;
}

static void collectControls(NSView *view, NSMutableArray<NSTextField *> *fields, NSMutableArray<NSButton *> *buttons) {
    if (view.isHiddenOrHasHiddenAncestor) return;
    if ([view isKindOfClass:[NSTextField class]] && [(NSTextField *)view isEditable])
        [fields addObject:(NSTextField *)view];
    if ([view isKindOfClass:[NSButton class]]) [buttons addObject:(NSButton *)view];
    for (NSView *child in view.subviews) collectControls(child, fields, buttons);
}

static void clickOwnButton(NSButton *button) {
    NSWindow *window = button.window;
    NSRect rect = [button convertRect:button.bounds toView:nil];
    NSPoint point = NSMakePoint(NSMidX(rect), NSMidY(rect));
    NSTimeInterval timestamp = NSProcessInfo.processInfo.systemUptime;
    // Events remain inside this application's queue; no global input injection.
    [NSApp postEvent:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point
        modifierFlags:0 timestamp:timestamp windowNumber:window.windowNumber
        context:nil eventNumber:0 clickCount:1 pressure:1] atStart:NO];
    [NSApp postEvent:[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point
        modifierFlags:0 timestamp:timestamp + 0.05 windowNumber:window.windowNumber
        context:nil eventNumber:1 clickCount:1 pressure:0] atStart:NO];
}

static void typeOwnKey(NSWindow *window, NSString *text, unsigned short keyCode) {
    NSTimeInterval timestamp = NSProcessInfo.processInfo.systemUptime;
    for (NSNumber *kind in @[@(NSEventTypeKeyDown), @(NSEventTypeKeyUp)]) {
        [NSApp postEvent:[NSEvent keyEventWithType:(NSEventType)kind.unsignedIntegerValue
            location:NSZeroPoint modifierFlags:0 timestamp:timestamp windowNumber:window.windowNumber
            context:nil characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:keyCode] atStart:NO];
    }
}

static void automateWindow(NSWindow *window) {
    NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    collectControls(window.contentView, fields, buttons);
    for (NSTextField *field in fields)
        fprintf(stderr, "Automation field: label=%s value=%s frame=%s action=%s\n",
                field.accessibilityLabel.UTF8String, field.stringValue.UTF8String,
                NSStringFromRect(field.frame).UTF8String,
                field.action ? NSStringFromSelector(field.action).UTF8String : "");
    NSString *desired = @"Cancel";
    if ([automation isEqualToString:@"edit-save"]) {
        NSTextField *chosen = nil;
        for (NSTextField *field in fields) {
            if ([field.accessibilityLabel isEqualToString:@"Reds"]) { chosen = field; break; }
        }
        // The installed ACR exposes no labels on its eight mixer value fields.
        // Only exercise the visually verified eight-row HSL layout; verify the
        // resulting semantic parameter from the saved XMP outside this process.
        bool hslVisible = false;
        for (NSButton *button in buttons) hslVisible |= [button.title isEqualToString:@"HSL"];
        if (!chosen && hslVisible && fields.count == 8) {
            NSArray *ordered = [fields sortedArrayUsingComparator:^NSComparisonResult(NSTextField *a, NSTextField *b) {
                CGFloat ay = [a convertRect:a.bounds toView:window.contentView].origin.y;
                CGFloat by = [b convertRect:b.bounds toView:window.contentView].origin.y;
                return ay < by ? NSOrderedAscending : ay > by ? NSOrderedDescending : NSOrderedSame;
            }];
            bool rowsMatch = true;
            NSRect previous = NSZeroRect;
            for (NSUInteger i = 0; i < ordered.count; ++i) {
                NSTextField *field = ordered[i];
                NSRect rect = [field convertRect:field.bounds toView:window.contentView];
                if (i && (fabs(rect.origin.x - previous.origin.x) > 1
                    || fabs(rect.origin.y - previous.origin.y - 31) > 1)) rowsMatch = false;
                previous = rect;
            }
            if (rowsMatch) chosen = ordered.firstObject;
        }
        if (chosen) {
            [chosen selectText:nil];
            typeOwnKey(window, @"1", 18);
            typeOwnKey(window, @"\t", 48);
            fprintf(stderr, "Automation typing 1 into first HSL row; saved XMP must confirm the parameter.\n");
            desired = @"Done";
        }
    }
    for (NSButton *button in buttons) {
        if ([button.title isEqualToString:desired]) {
            fprintf(stderr, "Automation clicking %s.\n", desired.UTF8String);
            clickOwnButton(button);
            return;
        }
    }
    fprintf(stderr, "Automation could not locate the requested button.\n");
}

static void observeWindows() {
    // Inspect only windows owned by this helper. No Accessibility or screen capture permissions.
    NSMutableSet *seen = [NSMutableSet set];
    NSTimer *timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *) {
        for (NSWindow *window in NSApp.windows) {
            if (!window.visible || [seen containsObject:window]) continue;
            [seen addObject:window];
            fprintf(stderr, "Window: %s\n", window.title.UTF8String);
            if (captureDirectory && [window.title hasPrefix:@"Camera Raw"]) {
                describeOwnedWindows();
                NSView *view = window.contentView;
                NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
                if (bitmap) {
                    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
                    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                    NSString *snapshot = [captureDirectory stringByAppendingPathComponent:@"camera-raw-window.png"];
                    NSError *captureError = nil;
                    if (![png writeToFile:snapshot options:NSDataWritingAtomic error:&captureError])
                        fprintf(stderr, "Window capture failed: %s\n", captureError.description.UTF8String);
                    else fprintf(stderr, "Window capture: %s\n", snapshot.UTF8String);
                }
            }
            if (![automation isEqualToString:@"none"] && [window.title hasPrefix:@"Camera Raw"]) {
                NSTimer *action = [NSTimer timerWithTimeInterval:2 repeats:NO block:^(NSTimer *) { automateWindow(window); }];
                [[NSRunLoop mainRunLoop] addTimer:action forMode:NSRunLoopCommonModes];
                [[NSRunLoop mainRunLoop] addTimer:action forMode:NSModalPanelRunLoopMode];
            }
            if (describeView(window.contentView)) {
                NSView *button = window.defaultButtonCell.controlView;
                if ([button isKindOfClass:[NSButton class]]) {
                    fprintf(stderr, "Dismissing this helper's unsupported-host alert.\n");
                    [(NSButton *)button performClick:nil];
                }
            }
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSModalPanelRunLoopMode];
}

// All calls use the SDK ABI, never guessed offsets or patched plug-in code.
using Entry = void (*)(int16, void *, intptr_t *, int16 *);

static int16 invoke(Entry entry, int16 selector, void *record, intptr_t *state) {
    int16 result = 0;
    fprintf(stderr, "Calling selector=%d\n", int(selector));
    entry(selector, record, state, &result);
    fprintf(stderr, "Returned selector=%d result=%d state=%p missingSuites=%d\n",
            int(selector), int(result), reinterpret_cast<void *>(*state), missingSuites);
    return result;
}

int main(int argc, const char *argv[]) {
    setbuf(stdout, nullptr);
    setbuf(stderr, nullptr);
    if (argc < 3) {
        fprintf(stderr, "usage: camera-raw-host-probe PLUGIN load|initialize|prepare|read IMAGE [HOST_SIGNATURE] [API_VERSION]\n");
        return 64;
    }
    @autoreleasepool {
        [NSApplication sharedApplication];
        if (argc > 9 && argv[9][0]) captureDirectory = [NSString stringWithUTF8String:argv[9]];
        if (argc > 10) automation = [NSString stringWithUTF8String:argv[10]];
        bool appEnvironment = argc > 7 && strcmp(argv[7], "app") == 0;
        [NSApp setActivationPolicy:appEnvironment ? NSApplicationActivationPolicyRegular : NSApplicationActivationPolicyAccessory];
        if (appEnvironment) {
            [NSApp finishLaunching];
            [NSApp activateIgnoringOtherApps:YES];
        }
        observeWindows();
        basic = {acquireSuite, releaseSuite, equalTokens, allocateBlock,
                 freeBlock, reallocateBlock, undefinedFunction};
        if (argc > 5) apiVersion = uint32_t(strtoul(argv[5], nullptr, 0));
        publicServices = argc > 6 && strcmp(argv[6], "public") == 0;
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        if (!bundle) { fprintf(stderr, "Not a plug-in bundle\n"); return 65; }
        PluginResources resources;
        if (argc > 8 && strcmp(argv[8], "resources") == 0 && !resources.open(bundle.bundleURL)) {
            fprintf(stderr, "Opening the plug-in resource map failed.\n");
            return 68;
        }
        fprintf(stderr, "Plugin: %s version=%s\n", path.UTF8String,
                [[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String]);
        NSError *error = nil;
        if (![bundle loadAndReturnError:&error]) {
            fprintf(stderr, "Bundle load failed: %s\n", error.description.UTF8String);
            return 66;
        }
        void *library = dlopen(bundle.executablePath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!library) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 66; }
        Entry format = reinterpret_cast<Entry>(dlsym(library, "EntryFM"));
        Entry filter = reinterpret_cast<Entry>(dlsym(library, "EntryFI"));
        fprintf(stderr, "Loaded: EntryFM=%p EntryFI=%p\n", format, filter);
        if (!format || !filter) return 67;
        if (strcmp(argv[2], "load") == 0) {
            fprintf(stderr, "Load-only complete; editor was NOT opened.\n");
            return 0;
        }
        intptr_t state = 0;
        PlatformData platform{};
        if (strcmp(argv[2], "initialize") != 0 && strcmp(argv[2], "prepare") != 0
            && strcmp(argv[2], "read") != 0 && strcmp(argv[2], "settings") != 0) return 64;
        FormatRecord record{};
        Str255 errorText{};
        record.sSPBasic = &basic;
        record.platformData = &platform;
        const char *signature = argc > 4 ? argv[4] : "PBrw";
        if (strlen(signature) != 4) return 64;
        record.hostSig = (uint32_t(uint8_t(signature[0])) << 24)
            | (uint32_t(uint8_t(signature[1])) << 16)
            | (uint32_t(uint8_t(signature[2])) << 8) | uint8_t(signature[3]);
        fprintf(stderr, "Diagnostic host signature: %.4s\n", signature);
        fprintf(stderr, "Diagnostic API version: %u.%u.%u\n", apiVersion >> 16,
                (apiVersion >> 8) & 255, apiVersion & 255);
        record.hostModes = 1 << plugInModeRGBColor;
        record.maxData = 256 * 1024 * 1024;
        record.abortProc = abortOperation;
        record.progressProc = reportProgress;
        record.errorString = &errorText;
        record.propertyProcs = &properties;
        if (publicServices) {
            record.handleProcs = &ProbeMemory::handles;
            record.bufferProcs = &ProbeMemory::buffers;
            record.advanceState = advanceState;
        }
        record.HostSupports32BitCoordinates = true;
        record.hostSupportsPluginOpeningFile = true;
        uint32 bulkFlags = 0;
        Handle bulkParams = nullptr;
        record.fileCount = 1;
        record.bulkMask = PIFmtBulkInvalPreviewMask | PIFmtBulkInvalMetaMask;
        record.bulkFlags = &bulkFlags;
        record.bulkParams = &bulkParams;
        NSURL *image = argc > 3 ? [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[3]]] : nil;
        if (strcmp(argv[2], "read") == 0 && !image) return 64;
        XPlatFileSpec file{};
        SPPlatformFileSpecificationW legacyFile{};
        if (image) {
            file.mFileSpecVersion = kXPlatFileSpecVersion;
            file.mFileReference = (__bridge CFURLRef)image;
            record.fileSpecX = &file;
            if (CFURLGetFSRef((__bridge CFURLRef)image, &legacyFile.mReference)) {
                record.fileSpec2 = &legacyFile;
            }
        }
        int16 result = invoke(format, formatSelectorLoad, &record, &state);
        if (!result && strcmp(argv[2], "initialize") != 0) {
            result = invoke(format, formatSelectorReadPrepare, &record, &state);
        }
        if (!result && (strcmp(argv[2], "read") == 0 || strcmp(argv[2], "settings") == 0)) {
            result = invoke(format, strcmp(argv[2], "settings") == 0 ? formatSelectorBulkSettings : formatSelectorReadStart, &record, &state);
            describeOwnedWindows();
            // Pixel transfer is outside this probe; finish releases a successful start.
            if (!result && strcmp(argv[2], "read") == 0) invoke(format, formatSelectorReadFinish, &record, &state);
        }
        if (errorText[0]) fprintf(stderr, "Plugin error: %.*s\n", int(errorText[0]), errorText + 1);
        invoke(format, formatSelectorUnload, &record, &state);
        fprintf(stderr, "Probe complete; successful calls alone do NOT establish a working editor.\n");
        // This short-lived process owns any plug-in state; do not unload code with live globals.
        return result ? 2 : (missingSuites ? 3 : 0);
    }
}
