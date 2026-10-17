// Settings-only Camera Raw host. Adobe's plug-in is loaded from the user's installation.
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#include <dlfcn.h>
#include "HostServices.hpp"
#include "InputFiles.hpp"

static NSString *resultPath;
static NSString *pluginVersion = @"";
static bool editorOpened = false;
static NSUInteger inputCount = 0;

static void writeResult(NSString *status, NSString *stage, int code) {
    NSDictionary *result = @{@"version": @1, @"status": status, @"stage": stage,
        @"code": @(code), @"editorOpened": @(editorOpened), @"pluginVersion": pluginVersion, @"inputCount": @(inputCount)};
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:&error];
    if (!data || ![data writeToFile:resultPath options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr, "Cannot write host result: %s\n", error.localizedDescription.UTF8String);
        _exit(74);
    }
}
static int fail(NSString *stage, int code) { writeResult(@"failed", stage, code); return 1; }

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
        return true;
    }
    ~PluginResources() {
        if (map != -1) { UseResFile(previous); CFBundleCloseBundleResourceMap(bundle, map); }
        if (bundle) CFRelease(bundle);
    }
};

#ifdef PHOTO_CAMERA_RAW_TESTING
#include "../../Tests/CameraRawHostChecks/Automation.hpp"
#endif

static NSTimer *observeWindows() {
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *) {
        for (NSWindow *window in NSApp.windows) {
            if (!window.visible || ![window.title hasPrefix:@"Camera Raw "]) continue;
            if (!editorOpened) {
                editorOpened = true;
                writeResult(@"editing", @"settings", 0);
#ifdef PHOTO_CAMERA_RAW_TESTING
                scheduleTestAction(window);
#endif
            }
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSModalPanelRunLoopMode];
    return timer;
}

using Entry = void (*)(int16, void *, intptr_t *, int16 *);
static int16 invoke(Entry entry, int16 selector, FormatRecord &record, intptr_t &state) {
    int16 result = 0;
    entry(selector, &record, &state, &result);
    return result;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
#ifdef PHOTO_CAMERA_RAW_TESTING
        if (argc != 4 && argc != 5) return 64;
        testAction = argc == 5 ? [NSString stringWithUTF8String:argv[4]] : @"cancel";
#else
        if (argc != 4) return 64;
#endif
        NSString *plugin = [NSString stringWithUTF8String:argv[1]];
        resultPath = [NSString stringWithUTF8String:argv[3]];
        writeResult(@"starting", @"launch", 0);
        InputFiles inputs;
        if (!inputs.load([NSString stringWithUTF8String:argv[2]])) return fail(@"images", 65);
        inputCount = inputs.urls.count;
        NSError *error = nil;
        NSBundle *bundle = [NSBundle bundleWithPath:plugin];
        if (!bundle || !bundle.executablePath) return fail(@"plugin", 65);
        pluginVersion = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];
        [NSApp activate];
        PluginResources resources;
        if (!resources.open(bundle.bundleURL)) return fail(@"resources", 68);
        if (![bundle loadAndReturnError:&error]) return fail(@"load", int(error.code));
        void *library = dlopen(bundle.executablePath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!library) return fail(@"load", 66);
        Entry entry = reinterpret_cast<Entry>(dlsym(library, "EntryFM"));
        if (!entry) return fail(@"entry", 67);

        FormatRecord record{};
        PlatformData platform{};
        Str255 errorText{};
        CameraRawServices::configure(record);
        record.platformData = &platform;
        record.errorString = &errorText;
        inputs.configure(record);
        // Deliberately omit PIFmtBulkOpenMask: ACR offers Done/Cancel, not pixel import.
        record.bulkMask = PIFmtBulkInvalPreviewMask | PIFmtBulkInvalMetaMask;

        intptr_t state = 0;
        NSString *stage = @"initialize";
        int16 result = invoke(entry, formatSelectorLoad, record, state);
        NSTimer *timer = nil;
        if (!result) {
            stage = @"prepare";
            result = invoke(entry, formatSelectorReadPrepare, record, state);
        }
        if (!result) {
            stage = @"settings";
            timer = observeWindows();
            result = invoke(entry, formatSelectorBulkSettings, record, state);
            [timer invalidate];
#ifdef PHOTO_CAMERA_RAW_TESTING
            fprintf(stderr, "Bulk result: %d inputs=%u finalCount=%u\n", int(result), unsigned(inputCount), unsigned(record.fileCount));
#endif
        }
        if (record.bulkExtraData) ProbeMemory::disposeHandle(record.bulkExtraData);
        int16 unloaded = invoke(entry, formatSelectorUnload, record, state);
        if (CameraRawServices::pixelTransferRequested || inputs.requestsPixels()) return fail(@"pixel-transfer", -30900);
        if (unloaded) return fail(@"unload", unloaded);
        // A normal dialog close is not proof that changes were saved. Never report it as such.
        if (editorOpened && (result == noErr || result == userCanceledErr)) {
            writeResult(@"closed", @"settings", result);
            return 0;
        }
        return fail(stage, result ? result : 69);
        // Keep the loaded library alive until process exit: ACR owns live static state.
    }
}
