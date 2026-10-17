// Panorama checks act exclusively on windows owned by the test helper.
static void describePanoramaText(NSView *view) {
    if ([view isKindOfClass:NSTextField.class]) fprintf(stderr, "Panorama text: %s\n", [(NSTextField *)view stringValue].UTF8String);
    for (NSView *child in view.subviews) describePanoramaText(child);
}
static void queuePanoramaCommand(NSWindow *window, bool automatic) {
    NSTimer *command = [NSTimer timerWithTimeInterval:0.01 repeats:NO block:^(NSTimer *) {
        [window makeFirstResponder:nil];
        for (NSString *key in @[@"a", @"m"]) {
            NSEventModifierFlags flags = NSEventModifierFlagCommand;
            if (automatic && [key isEqualToString:@"m"]) flags |= NSEventModifierFlagShift;
            NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags
                timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
                characters:key charactersIgnoringModifiers:key isARepeat:NO keyCode:[key isEqualToString:@"a"] ? 0 : 46];
            BOOL handled = [window performKeyEquivalent:event];
            fprintf(stderr, "Panorama command %s handled=%d\n", key.UTF8String, int(handled));
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:command forMode:NSRunLoopCommonModes];
    [[NSRunLoop mainRunLoop] addTimer:command forMode:NSModalPanelRunLoopMode];
}
static void schedulePanoramaTest() {
    __block int phase = 0;
    __block NSWindow *editor = nil;
    __block int ticks = 0;
    NSMutableSet *seen = [NSMutableSet set];
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        ++ticks;
        for (NSWindow *window in NSApp.windows) {
            if (!window.visible) continue;
            NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
            NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
            collectControls(window.contentView, fields, buttons);
            if (![seen containsObject:window]) {
                [seen addObject:window];
                fprintf(stderr, "Panorama window: %s class=%s\n", window.title.UTF8String, NSStringFromClass(window.class).UTF8String);
                for (NSButton *button in buttons) fprintf(stderr, "Panorama button: %s enabled=%d\n", button.title.UTF8String, int(button.enabled));
                if ([NSStringFromClass(window.class) containsString:@"Alert"]) {
                    describePanoramaText(window.contentView);
                    _exit(77);
                }
            }
            if (phase == 0 && [window.title hasPrefix:@"Camera Raw "]) {
                bool done = false, cancel = false;
                for (NSButton *button in buttons) {
                    if ([button.title isEqualToString:@"Done"]) done = button.enabled;
                    if ([button.title isEqualToString:@"Cancel"]) cancel = button.enabled;
                }
                if (!done || !cancel) continue;
                editor = window;
                [window makeKeyAndOrderFront:nil];
                [window makeFirstResponder:nil];
                bool automatic = [testAction isEqualToString:@"panorama-auto"];
                phase = automatic ? 4 : 1;
                queuePanoramaCommand(window, automatic);
                fprintf(stderr, "Panorama requested for %lu inputs.\n", (unsigned long)inputCount);
                return;
            }
            if (phase == 1 && window != editor) {
                for (NSButton *button in buttons) if ([button.title hasPrefix:@"Merge"] && button.enabled) {
                    fprintf(stderr, "Panorama preview ready.\n");
                    phase = 2;
                    // Merge may synchronously run a save panel. Keep this polling
                    // timer free to service that nested modal loop.
                    NSTimer *action = [NSTimer timerWithTimeInterval:0.01 repeats:NO block:^(NSTimer *) {
                        [NSApp sendAction:button.action to:button.target from:button];
                    }];
                    [[NSRunLoop mainRunLoop] addTimer:action forMode:NSRunLoopCommonModes];
                    [[NSRunLoop mainRunLoop] addTimer:action forMode:NSModalPanelRunLoopMode];
                    return;
                }
            }
            if (phase == 2 && [window isKindOfClass:NSSavePanel.class]) {
                NSSavePanel *panel = (NSSavePanel *)window;
                fprintf(stderr, "Panel appearance: app=%s panel=%s current=%s\n", NSApp.effectiveAppearance.name.UTF8String,
                    panel.effectiveAppearance.name.UTF8String, NSAppearance.currentAppearance.name.UTF8String);
                panel.directoryURL = [NSURL fileURLWithPath:[resultPath stringByDeletingLastPathComponent]];
                panel.nameFieldStringValue = @"panorama-result.dng";
                fprintf(stderr, "Panorama save requested.\n");
                phase = 3;
                NSTimer *save = [NSTimer timerWithTimeInterval:0.5 repeats:NO block:^(NSTimer *) { [panel ok:nil]; }];
                [[NSRunLoop mainRunLoop] addTimer:save forMode:NSRunLoopCommonModes];
                [[NSRunLoop mainRunLoop] addTimer:save forMode:NSModalPanelRunLoopMode];
                return;
            }
        }
        if (phase == 1 && ticks % 6 == 0 && (!NSApp.modalWindow || NSApp.modalWindow == editor)) {
            fprintf(stderr, "Retry panorama: active=%d key=%d modal=%s responder=%s\n", int(NSApp.active), int(editor.keyWindow),
                NSApp.modalWindow.title.UTF8String, NSStringFromClass(editor.firstResponder.class).UTF8String);
            [editor makeFirstResponder:nil];
            queuePanoramaCommand(editor, false);
        }
        if (phase >= 2) {
            NSString *folder = [resultPath stringByDeletingLastPathComponent];
            for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder error:nil]) {
                if ([file.pathExtension.lowercaseString isEqualToString:@"dng"] && !editor.attachedSheet) {
                    fprintf(stderr, "Panorama output observed: %s\n", file.UTF8String);
                    typeOwnKey(editor, @"\033", 53);
                    [timer invalidate];
                    return;
                }
            }
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSModalPanelRunLoopMode];
}
