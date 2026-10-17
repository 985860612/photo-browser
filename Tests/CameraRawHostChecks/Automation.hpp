// Included only in test builds; events stay inside the helper process.
static NSString *testAction;
static void collectControls(NSView *view, NSMutableArray<NSTextField *> *fields, NSMutableArray<NSButton *> *buttons) {
    if (view.isHiddenOrHasHiddenAncestor) return;
    if ([view isKindOfClass:[NSTextField class]] && [(NSTextField *)view isEditable])
        [fields addObject:(NSTextField *)view];
    if ([view isKindOfClass:[NSButton class]]) [buttons addObject:(NSButton *)view];
    for (NSView *child in view.subviews) collectControls(child, fields, buttons);
}

static void typeOwnKey(NSWindow *window, NSString *text, unsigned short keyCode, NSEventModifierFlags flags = 0) {
    NSTimeInterval timestamp = NSProcessInfo.processInfo.systemUptime;
    for (NSNumber *kind in @[@(NSEventTypeKeyDown), @(NSEventTypeKeyUp)]) {
        [window sendEvent:[NSEvent keyEventWithType:(NSEventType)kind.unsignedIntegerValue
            location:NSZeroPoint modifierFlags:flags timestamp:timestamp windowNumber:window.windowNumber
            context:nil characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:keyCode]];
    }
}

#include "Panorama.hpp"

static void automateWindow(NSWindow *window) {
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    collectControls(window.contentView, fields, buttons);
    for (NSTextField *field in fields)
        fprintf(stderr, "Automation field: label=%s value=%s frame=%s action=%s\n",
                field.accessibilityLabel.UTF8String, field.stringValue.UTF8String,
                NSStringFromRect(field.frame).UTF8String,
                field.action ? NSStringFromSelector(field.action).UTF8String : "");
    NSString *desired = [testAction isEqualToString:@"done"] ? @"Done" : @"Cancel";
    bool discardEdit = [testAction isEqualToString:@"edit-cancel"];
    NSString *newValue = discardEdit ? @"2" : @"1";
    NSTextField *edited = nil;
    if ([testAction isEqualToString:@"edit-save"] || discardEdit) {
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
            typeOwnKey(window, newValue, discardEdit ? 19 : 18);
            typeOwnKey(window, @"\t", 48);
            fprintf(stderr, "Automation typing %s into first HSL row; saved XMP must confirm the parameter.\n", newValue.UTF8String);
            edited = chosen;
            desired = discardEdit ? @"Cancel" : @"Done";
        }
    }
    for (NSButton *button in buttons) {
        if ([button.title isEqualToString:desired]) {
            fprintf(stderr, "Automation clicking %s.\n", desired.UTF8String);
            fprintf(stderr, "Button key=%s flags=%lu action=%s target=%s enabled=%d\n", button.keyEquivalent.debugDescription.UTF8String,
                (unsigned long)button.keyEquivalentModifierMask, NSStringFromSelector(button.action).UTF8String,
                NSStringFromClass([button.target class]).UTF8String, int(button.enabled));
            NSTimer *commit = [NSTimer timerWithTimeInterval:0.75 repeats:NO block:^(NSTimer *) {
                if (edited && ![@[newValue, [@"+" stringByAppendingString:newValue]] containsObject:edited.stringValue]) {
                    fprintf(stderr, "Automation value was not committed: %s\n", edited.stringValue.UTF8String);
                    _exit(75); // Do not run ACR globals' destructors inside its modal loop.
                }
                if ([desired isEqualToString:@"Cancel"]) typeOwnKey(window, @"\033", 53);
                else [NSApp sendAction:button.action to:button.target from:button];
                // Retry only the close action, never the parameter edit.
                NSTimer *retry = [NSTimer timerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
                    if (!window.visible || !button.window) { [timer invalidate]; return; }
                    if (!window.attachedSheet && button.enabled) {
                        if ([desired isEqualToString:@"Cancel"]) typeOwnKey(window, @"\033", 53);
                        else [NSApp sendAction:button.action to:button.target from:button];
                    }
                }];
                [[NSRunLoop mainRunLoop] addTimer:retry forMode:NSRunLoopCommonModes];
                [[NSRunLoop mainRunLoop] addTimer:retry forMode:NSModalPanelRunLoopMode];
            }];
            [[NSRunLoop mainRunLoop] addTimer:commit forMode:NSRunLoopCommonModes];
            [[NSRunLoop mainRunLoop] addTimer:commit forMode:NSModalPanelRunLoopMode];
            return;
        }
    }
    fprintf(stderr, "Automation could not locate the requested button.\n");
}


static void scheduleTestAction(NSWindow *) {
    if ([testAction hasPrefix:@"panorama"]) { schedulePanoramaTest(); return; }
    // ACR can expose a titled loading window before the editor controls exist.
    // Wait for the verified mixer layout instead of cancelling a partially built UI.
    __block int attempts = 0;
    __block bool pickedMixer = false;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        ++attempts;
        for (NSWindow *window in NSApp.windows) {
            if (!window.visible || ![window.title hasPrefix:@"Camera Raw "]) continue;
            NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
            NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
            collectControls(window.contentView, fields, buttons);
            bool hsl = false;
            bool ready = true, done = false, cancel = false;
            for (NSTextField *field in fields) ready &= field.enabled;
            for (NSButton *button in buttons) hsl |= [button.title isEqualToString:@"HSL"];
            for (NSButton *button in buttons) {
                if ([button.title isEqualToString:@"Done"]) done = button.enabled;
                if ([button.title isEqualToString:@"Cancel"]) cancel = button.enabled;
            }
            if (!hsl && !pickedMixer && buttons.count >= 3) {
                pickedMixer = true;
                [window makeKeyAndOrderFront:nil];
                [NSApp activateIgnoringOtherApps:YES];
                // Adobe's documented Pick Color Mixer shortcut (Command+5).
                // https://helpx.adobe.com/camera-raw/desktop/get-started/overview-and-setup/default-keyboard-shortcuts.html
                typeOwnKey(window, @"5", 23, NSEventModifierFlagCommand);
            }
            if (attempts == 8) {
                fprintf(stderr, "Waiting for mixer: fields=%lu buttons=%lu\n", (unsigned long)fields.count, (unsigned long)buttons.count);
                for (NSButton *button in buttons) fprintf(stderr, "Visible button: %s\n", button.title.UTF8String);
                NSView *view = window.contentView;
                NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
                if (bitmap) {
                    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
                    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                    [png writeToFile:[resultPath stringByAppendingString:@".png"] atomically:YES];
                }
            }
            if (hsl && ready && done && cancel && fields.count == 8) {
                [timer invalidate]; automateWindow(window); return;
            }
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSModalPanelRunLoopMode];
}
