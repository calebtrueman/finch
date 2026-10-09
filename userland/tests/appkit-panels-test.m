/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-panels-test: NSAlert, NSSavePanel/NSOpenPanel and
 * NSWorkspace/NSRunningApplication without showing anything: alerts' state,
 * buttons, return codes and key equivalents, the error and legacy
 * factories, layout; panels' defaults and setters and how URL joins the
 * directory and the name; the workspace's constants, the current
 * application, packages and types of files in a temporary folder, icons'
 * sizes, open configurations, duplicating and recycling files. Prints
 * everything; run it against Apple's AppKit and Finch's (DYLD_FRAMEWORK_PATH,
 * FINCH_FONT_DIRS) and diff all but the first line, which is where NSAlert
 * came from. Nothing here runs a panel or an alert (Apple's would show).
 */
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>

extern char **environ;

static void out(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

static void
out(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("%s\n", [s UTF8String]);
}

#define SHOW(fmt, expr)                                                         \
    do {                                                                        \
        @try {                                                                  \
            out(@"  %s: " fmt, #expr, expr);                                    \
        } @catch (NSException * e) {                                            \
            out(@"  %s: raises %@", #expr, e.name);                             \
        }                                                                       \
    } while (0)

#define DO(stmt)                                                                \
    do {                                                                        \
        @try {                                                                  \
            stmt;                                                               \
        } @catch (NSException * e) {                                            \
            out(@"  %s: raises %@", #stmt, e.name);                             \
        }                                                                       \
    } while (0)

static NSString *
key_desc(NSString *k)
{
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < k.length; i++) {
        unichar c = [k characterAtIndex:i];
        if (c < ' ' || c > '~')
            [s appendFormat:@"\\x%02x", c];
        else
            [s appendFormat:@"%C", c];
    }
    return s;
}

static NSString *
button_desc(NSButton *b, NSAlert *a)
{
    return [NSString stringWithFormat:@"'%@' tag %ld key '%@' mask %lx target-is-alert %d enabled %d", b.title,
                                      (long)b.tag, key_desc(b.keyEquivalent), (unsigned long)b.keyEquivalentModifierMask,
                                      b.target == a, b.isEnabled];
}

/* Paths under the home folder print from "~", so runs as different users compare. */
static NSString *
home_relative(id u)
{
    if (!u)
        return @"(nil)";
    NSString *s = [u isKindOfClass:[NSURL class]] ? [u absoluteString] : u;
    NSString *home = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES].absoluteString;
    if ([s hasPrefix:home])
        return [@"~/" stringByAppendingString:[s substringFromIndex:home.length]];
    if ([s hasPrefix:NSHomeDirectory()])
        return [@"~" stringByAppendingString:[s substringFromIndex:NSHomeDirectory().length]];
    return s;
}

static NSString *
list(NSArray *a)
{
    if (!a)
        return @"(nil)";
    NSMutableArray *m = [NSMutableArray array];
    for (id x in a)
        [m addObject:[x description]];
    return [NSString stringWithFormat:@"[%@]", [m componentsJoinedByString:@", "]];
}

static void
spin(void)
{
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
}

#pragma mark - NSAlert

@interface HelpDelegate : NSObject <NSAlertDelegate>
@end
@implementation HelpDelegate
- (BOOL)alertShowHelp:(NSAlert *)alert
{
    return YES;
}
@end

static void
alerts(void)
{
    out(@"NSAlert");
    out(@"  return codes %ld %ld %ld; legacy %ld %ld %ld %ld; modal %ld %ld %ld %ld %ld", (long)NSAlertFirstButtonReturn,
        (long)NSAlertSecondButtonReturn, (long)NSAlertThirdButtonReturn, (long)NSAlertDefaultReturn,
        (long)NSAlertAlternateReturn, (long)NSAlertOtherReturn, (long)NSAlertErrorReturn, (long)NSModalResponseOK,
        (long)NSModalResponseCancel, (long)NSModalResponseStop, (long)NSModalResponseAbort,
        (long)NSModalResponseContinue);
    NSAlert *a = [[NSAlert alloc] init];
    SHOW(@"'%@'", a.messageText);
    SHOW(@"'%@'", a.informativeText);
    SHOW(@"%lu", (unsigned long)a.alertStyle);
    SHOW(@"%d", a.showsHelp);
    SHOW(@"%@", a.helpAnchor);
    SHOW(@"%d", a.showsSuppressionButton);
    SHOW(@"%@", a.accessoryView);
    SHOW(@"%@", a.delegate);
    SHOW(@"%@", NSStringFromSize(a.icon.size));
    SHOW(@"%d", a.icon != nil);
    SHOW(@"%d", a.window != nil);
    SHOW(@"%d", [a.window isKindOfClass:[NSPanel class]]);
    SHOW(@"%lu", (unsigned long)a.buttons.count);
    out(@"  implicit button: %@", button_desc(a.buttons[0], a));
    SHOW(@"%d", [a.suppressionButton isKindOfClass:[NSButton class]]);
    SHOW(@"'%@'", a.suppressionButton.title);
    SHOW(@"%ld", (long)a.suppressionButton.state);
    SHOW(@"%d", a.suppressionButton.superview != nil);

    out(@"buttons");
    for (NSString *t in @[ @"Save", @"Cancel", @"Don't Save", @"Other", @"cancel", @"Don’t Save", @"Don't save" ]) {
        NSButton *b = [a addButtonWithTitle:t];
        out(@"  add '%@': %@ in buttons %d", t, button_desc(b, a), [a.buttons containsObject:b]);
    }
    SHOW(@"%lu", (unsigned long)a.buttons.count);
    NSAlert *c = [[NSAlert alloc] init];
    out(@"  first Cancel: %@", button_desc([c addButtonWithTitle:@"Cancel"], c));
    out(@"  then OK: %@", button_desc([c addButtonWithTitle:@"OK"], c));
    NSAlert *d = [[NSAlert alloc] init];
    out(@"  first Don't Save: %@", button_desc([d addButtonWithTitle:@"Don't Save"], d));
    out(@"  then Save: %@", button_desc([d addButtonWithTitle:@"Save"], d));

    out(@"setters");
    DO(a.messageText = (NSString *_Nonnull)nil);
    DO(a.informativeText = (NSString *_Nonnull)nil);
    a.messageText = @"Message";
    a.informativeText = @"Informative";
    SHOW(@"'%@'", a.messageText);
    SHOW(@"'%@'", a.informativeText);
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(10, 20)];
    a.icon = img;
    SHOW(@"%d", a.icon == img);
    a.icon = nil;
    SHOW(@"%@", NSStringFromSize(a.icon.size));
    a.alertStyle = NSAlertStyleCritical;
    SHOW(@"%lu", (unsigned long)a.alertStyle);
    a.helpAnchor = @"anchor";
    SHOW(@"%@", a.helpAnchor);
    SHOW(@"%d", a.showsHelp);
    a.showsHelp = YES;
    SHOW(@"%d", a.showsHelp);
    HelpDelegate *hd = [HelpDelegate new];
    a.delegate = hd;
    SHOW(@"%d", a.delegate == hd);

    out(@"layout");
    NSView *acc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 30)];
    a.accessoryView = acc;
    a.showsSuppressionButton = YES;
    SHOW(@"'%@'", a.suppressionButton.title);
    [a layout];
    SHOW(@"'%@'", a.suppressionButton.title);
    SHOW(@"%d", a.suppressionButton.superview != nil);
    SHOW(@"%@", NSStringFromSize(acc.frame.size));
    SHOW(@"%d", acc.superview != nil);
    SHOW(@"%d", [acc isDescendantOf:a.window.contentView]);
    BOOL all = YES;
    for (NSButton *b in a.buttons)
        all &= [b isDescendantOf:a.window.contentView];
    SHOW(@"%d", all);
    SHOW(@"%d", a.window.isVisible);
    NSAlert *e = [[NSAlert alloc] init];
    e.messageText = @"Hello";
    [e layout];
    SHOW(@"%lu", (unsigned long)e.buttons.count);
    SHOW(@"%d", [e.buttons[0] isDescendantOf:e.window.contentView]);
    SHOW(@"%d", e.window.contentView.frame.size.width > 200);

    out(@"alertWithError");
    NSError *err = [NSError errorWithDomain:NSCocoaErrorDomain code:4 userInfo:@{
        NSLocalizedRecoverySuggestionErrorKey : @"Try again",
        NSLocalizedRecoveryOptionsErrorKey : @[ @"Retry", @"Give up", @"Cancel" ]
    }];
    NSAlert *x = [NSAlert alertWithError:err];
    SHOW(@"'%@'", x.messageText);
    SHOW(@"'%@'", x.informativeText);
    SHOW(@"%lu", (unsigned long)x.alertStyle);
    for (NSButton *b in x.buttons)
        out(@"  %@", button_desc(b, x));
    x = [NSAlert alertWithError:[NSError errorWithDomain:@"X" code:1 userInfo:nil]];
    SHOW(@"'%@'", x.messageText);
    SHOW(@"'%@'", x.informativeText);
    for (NSButton *b in x.buttons)
        out(@"  %@", button_desc(b, x));
    x = [NSAlert alertWithError:[NSError errorWithDomain:@"X" code:1 userInfo:@{
                 NSLocalizedDescriptionKey : @"Desc",
                 NSHelpAnchorErrorKey : @"anc"
             }]];
    SHOW(@"'%@'", x.messageText);
    SHOW(@"%@", x.helpAnchor);
    SHOW(@"%d", x.showsHelp);

    out(@"alertWithMessageText");
    x = [NSAlert alertWithMessageText:@"M" defaultButton:nil alternateButton:@"Alt" otherButton:@"Oth"
            informativeTextWithFormat:@"n=%d", 3];
    SHOW(@"'%@'", x.messageText);
    SHOW(@"'%@'", x.informativeText);
    for (NSButton *b in x.buttons)
        out(@"  %@", button_desc(b, x));
    x = [NSAlert alertWithMessageText:nil defaultButton:@"D" alternateButton:nil otherButton:@"Cancel"
            informativeTextWithFormat:@""];
    SHOW(@"'%@'", x.messageText);
    for (NSButton *b in x.buttons)
        out(@"  %@", button_desc(b, x));
}

#pragma mark - Panels

static void
panel_state(NSSavePanel *p)
{
    SHOW(@"%@", p.title);
    SHOW(@"%@", p.prompt);
    SHOW(@"'%@'", p.message);
    SHOW(@"%@", p.nameFieldLabel);
    SHOW(@"%@", p.nameFieldStringValue);
    SHOW(@"%@", home_relative(p.directoryURL));
    SHOW(@"%@", home_relative(p.URL));
    SHOW(@"%@", list(p.allowedContentTypes));
    SHOW(@"%@", list(p.allowedFileTypes));
    SHOW(@"%d", p.allowsOtherFileTypes);
    SHOW(@"%d", p.canCreateDirectories);
    SHOW(@"%d", p.canSelectHiddenExtension);
    SHOW(@"%d", p.isExtensionHidden);
    SHOW(@"%d", p.treatsFilePackagesAsDirectories);
    SHOW(@"%d", p.showsHiddenFiles);
    SHOW(@"%d", p.showsTagField);
    SHOW(@"%@", list(p.tagNames));
    SHOW(@"%d", p.isExpanded);
    SHOW(@"%@", p.accessoryView);
    SHOW(@"%@", p.delegate);
    SHOW(@"%d", p.showsContentTypes);
    SHOW(@"%@", p.identifier);
    SHOW(@"%@", home_relative(p.filename));
    SHOW(@"%@", home_relative(p.directory));
    SHOW(@"%@", p.requiredFileType);
    SHOW(@"%d", p.isVisible);
    if ([p isKindOfClass:[NSOpenPanel class]]) {
        NSOpenPanel *o = (NSOpenPanel *)p;
        SHOW(@"%d", o.canChooseFiles);
        SHOW(@"%d", o.canChooseDirectories);
        SHOW(@"%d", o.resolvesAliases);
        SHOW(@"%d", o.allowsMultipleSelection);
        SHOW(@"%d", o.isAccessoryViewDisclosed);
        SHOW(@"%@", list(o.URLs));
        SHOW(@"%d", o.canDownloadUbiquitousContents);
        SHOW(@"%d", o.canResolveUbiquitousConflicts);
        SHOW(@"%@", list(o.filenames));
    }
}

static void
panels(void)
{
    out(@"NSSavePanel");
    NSSavePanel *s = [NSSavePanel savePanel];
    SHOW(@"%d", [s isKindOfClass:[NSPanel class]]);
    SHOW(@"%d", [NSSavePanel savePanel] != s);
    panel_state(s);
    out(@"NSOpenPanel");
    NSOpenPanel *o = [NSOpenPanel openPanel];
    SHOW(@"%d", [o isKindOfClass:[NSSavePanel class]]);
    panel_state(o);

    out(@"save panel setters");
    s.directoryURL = [NSURL fileURLWithPath:@"/tmp"];
    spin();
    SHOW(@"%@", s.directoryURL);
    SHOW(@"%@", s.URL);
    s.nameFieldStringValue = @"Doc";
    spin();
    SHOW(@"%@", s.nameFieldStringValue);
    SHOW(@"%@", s.URL);
    s.allowedContentTypes = @[ UTTypePlainText ];
    spin();
    SHOW(@"%@", list(s.allowedContentTypes));
    SHOW(@"%@", list(s.allowedFileTypes));
    SHOW(@"%@", s.URL);
    s.allowedContentTypes = @[ UTTypePNG, UTTypeJPEG ];
    SHOW(@"%@", list(s.allowedFileTypes));
    SHOW(@"%@", s.requiredFileType);
    s.allowedFileTypes = @[ @"md", @"public.html", @"txt" ];
    SHOW(@"%@", list(s.allowedContentTypes));
    SHOW(@"%@", list(s.allowedFileTypes));
    s.allowedContentTypes = @[];
    SHOW(@"%@", list(s.allowedContentTypes));
    SHOW(@"%@", list(s.allowedFileTypes));
    s.allowedFileTypes = @[];
    SHOW(@"%@", list(s.allowedFileTypes));
    s.title = @"Export";
    SHOW(@"%@", s.title);
    s.title = (NSString *_Nonnull)nil;
    SHOW(@"%@", s.title);
    s.prompt = @"Go";
    SHOW(@"%@", s.prompt);
    s.message = @"Pick a place";
    SHOW(@"%@", s.message);
    s.message = (NSString *_Nonnull)nil;
    SHOW(@"'%@'", s.message);
    s.nameFieldLabel = @"Export As:";
    SHOW(@"%@", s.nameFieldLabel);
    s.canCreateDirectories = NO;
    SHOW(@"%d", s.canCreateDirectories);
    s.showsHiddenFiles = YES;
    SHOW(@"%d", s.showsHiddenFiles);
    s.treatsFilePackagesAsDirectories = YES;
    SHOW(@"%d", s.treatsFilePackagesAsDirectories);
    s.allowsOtherFileTypes = YES;
    SHOW(@"%d", s.allowsOtherFileTypes);
    s.canSelectHiddenExtension = YES;
    SHOW(@"%d", s.canSelectHiddenExtension);
    s.showsTagField = NO;
    SHOW(@"%d", s.showsTagField);
    s.tagNames = @[ @"Red" ];
    SHOW(@"%@", list(s.tagNames));
    s.identifier = @"export";
    SHOW(@"%@", s.identifier);
    NSView *acc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 40)];
    s.accessoryView = acc;
    SHOW(@"%d", s.accessoryView == acc);
    SHOW(@"%@", NSStringFromSize(acc.frame.size));
    s.directoryURL = nil;
    spin();
    SHOW(@"%@", home_relative(s.directoryURL));
    s.directoryURL = [NSURL fileURLWithPath:@"/nonexistent/dir"];
    spin();
    SHOW(@"%@", s.directoryURL);
    s.directoryURL = [NSURL URLWithString:@"http://example.com/"];
    spin();
    SHOW(@"%@", s.directoryURL);
    s.directoryURL = [NSURL fileURLWithPath:@"/usr"];
    s.nameFieldStringValue = @"notes.txt";
    spin();
    SHOW(@"%@", s.URL);
    SHOW(@"%@", s.filename);
    SHOW(@"%@", s.directory);

    out(@"open panel setters");
    o.directoryURL = [NSURL fileURLWithPath:@"/tmp"];
    spin();
    SHOW(@"%@", o.directoryURL);
    SHOW(@"%@", o.URL);
    o.nameFieldStringValue = @"x";
    spin();
    SHOW(@"%@", o.nameFieldStringValue);
    o.canChooseFiles = NO;
    o.canChooseDirectories = YES;
    o.allowsMultipleSelection = YES;
    o.resolvesAliases = NO;
    SHOW(@"%d", o.canChooseFiles);
    SHOW(@"%d", o.canChooseDirectories);
    SHOW(@"%d", o.allowsMultipleSelection);
    SHOW(@"%d", o.resolvesAliases);
    SHOW(@"%@", list(o.URLs));
    SHOW(@"%@", o.prompt);
    o.prompt = @"Choose";
    SHOW(@"%@", o.prompt);
    out(@"  file handling panel buttons %ld %ld", (long)NSFileHandlingPanelOKButton, (long)NSFileHandlingPanelCancelButton);
}

#pragma mark - NSWorkspace

static void
constants(void)
{
    out(@"workspace constants");
#define C(name) out(@"  %s = %@", #name, name)
    C(NSWorkspaceApplicationKey);
    C(NSWorkspaceWillLaunchApplicationNotification);
    C(NSWorkspaceDidLaunchApplicationNotification);
    C(NSWorkspaceDidTerminateApplicationNotification);
    C(NSWorkspaceDidHideApplicationNotification);
    C(NSWorkspaceDidUnhideApplicationNotification);
    C(NSWorkspaceDidActivateApplicationNotification);
    C(NSWorkspaceDidDeactivateApplicationNotification);
    C(NSWorkspaceVolumeLocalizedNameKey);
    C(NSWorkspaceVolumeURLKey);
    C(NSWorkspaceVolumeOldLocalizedNameKey);
    C(NSWorkspaceVolumeOldURLKey);
    C(NSWorkspaceDidMountNotification);
    C(NSWorkspaceDidUnmountNotification);
    C(NSWorkspaceWillUnmountNotification);
    C(NSWorkspaceDidRenameVolumeNotification);
    C(NSWorkspaceWillPowerOffNotification);
    C(NSWorkspaceWillSleepNotification);
    C(NSWorkspaceDidWakeNotification);
    C(NSWorkspaceScreensDidSleepNotification);
    C(NSWorkspaceScreensDidWakeNotification);
    C(NSWorkspaceSessionDidBecomeActiveNotification);
    C(NSWorkspaceSessionDidResignActiveNotification);
    C(NSWorkspaceDidChangeFileLabelsNotification);
    C(NSWorkspaceActiveSpaceDidChangeNotification);
    C(NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification);
    C(NSWorkspaceDesktopImageScalingKey);
    C(NSWorkspaceDesktopImageAllowClippingKey);
    C(NSWorkspaceDesktopImageFillColorKey);
    C(NSWorkspaceLaunchConfigurationAppleEvent);
    C(NSWorkspaceLaunchConfigurationArguments);
    C(NSWorkspaceLaunchConfigurationEnvironment);
    C(NSWorkspaceLaunchConfigurationArchitecture);
    C(NSWorkspaceMoveOperation);
    C(NSWorkspaceCopyOperation);
    C(NSWorkspaceLinkOperation);
    C(NSWorkspaceCompressOperation);
    C(NSWorkspaceDecompressOperation);
    C(NSWorkspaceEncryptOperation);
    C(NSWorkspaceDecryptOperation);
    C(NSWorkspaceDestroyOperation);
    C(NSWorkspaceRecycleOperation);
    C(NSWorkspaceDuplicateOperation);
    C(NSWorkspaceDidPerformFileOperationNotification);
    C(NSPlainFileType);
    C(NSDirectoryFileType);
    C(NSApplicationFileType);
    C(NSFilesystemFileType);
    C(NSShellCommandFileType);
#undef C
}

static void
running(void)
{
    out(@"NSRunningApplication");
    NSRunningApplication *c = [NSRunningApplication currentApplication];
    char buf[PATH_MAX], real[PATH_MAX];
    uint32_t size = sizeof buf;
    _NSGetExecutablePath(buf, &size);
    NSString *exe = [NSString stringWithUTF8String:realpath(buf, real) ?: buf];
    SHOW(@"%d", c.processIdentifier == getpid());
    SHOW(@"%@", c.bundleIdentifier);
    SHOW(@"%d", [c.bundleURL isEqual:[NSURL fileURLWithPath:exe isDirectory:YES]]);
    SHOW(@"%d", [c.executableURL.path isEqualToString:exe]);
    SHOW(@"%d", [c.localizedName isEqualToString:exe.lastPathComponent]);
    SHOW(@"%d", c.activationPolicy == NSApp.activationPolicy);
    SHOW(@"%d", c.isActive);
    SHOW(@"%d", c.isHidden);
    SHOW(@"%d", c.isTerminated);
    SHOW(@"%@", NSStringFromSize(c.icon.size));
    SHOW(@"%ld", (long)c.executableArchitecture);
    SHOW(@"%d", c.ownsMenuBar);
    SHOW(@"%d", [NSRunningApplication currentApplication] == c);
    SHOW(@"%d", [[NSRunningApplication currentApplication] isEqual:c]);
    NSRunningApplication *r = [NSRunningApplication runningApplicationWithProcessIdentifier:getpid()];
    SHOW(@"%d", [r isEqual:c]);
    SHOW(@"%d", [r.localizedName isEqualToString:c.localizedName]);
    SHOW(@"%@", [NSRunningApplication runningApplicationWithProcessIdentifier:99999]);
    pid_t pid;
    char *args[] = {"/bin/sleep", "5", NULL};
    posix_spawn(&pid, "/bin/sleep", NULL, NULL, args, environ);
    SHOW(@"%@", [NSRunningApplication runningApplicationWithProcessIdentifier:pid]);
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);
    SHOW(@"%lu", (unsigned long)[NSRunningApplication runningApplicationsWithBundleIdentifier:@"org.finch.none"].count);
    SHOW(@"%d", [[NSWorkspace sharedWorkspace].runningApplications containsObject:c]);

    out(@"NSWorkspaceOpenConfiguration");
    NSWorkspaceOpenConfiguration *oc = [NSWorkspaceOpenConfiguration configuration];
    SHOW(@"%d", oc.activates);
    SHOW(@"%d", oc.addsToRecentItems);
    SHOW(@"%d", oc.createsNewApplicationInstance);
    SHOW(@"%@", list(oc.arguments));
    SHOW(@"%lu", (unsigned long)oc.environment.count);
    SHOW(@"%d", oc.hides);
    SHOW(@"%d", oc.hidesOthers);
    SHOW(@"%d", oc.promptsUserIfNeeded);
    SHOW(@"%d", oc.requiresUniversalLinks);
    SHOW(@"%d", oc.allowsRunningApplicationSubstitution);
    SHOW(@"%d", oc.isForPrinting);
    SHOW(@"%ld", (long)oc.architecture);
    SHOW(@"%@", oc.appleEvent);
    oc.arguments = @[ @"-a" ];
    oc.activates = NO;
    NSWorkspaceOpenConfiguration *oc2 = [oc copy];
    SHOW(@"%@", list(oc2.arguments));
    SHOW(@"%d", oc2.activates);
}

static NSString *tmp;

static void
make_tree(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"finch-panels-%d", getpid()]];
    [fm removeItemAtPath:tmp error:nil];
    for (NSString *d in @[ @"Plain", @"Test.app/Contents/MacOS", @"X.bundle", @"Thing.foo", @"Dup/E.app" ])
        [fm createDirectoryAtPath:[tmp stringByAppendingPathComponent:d] withIntermediateDirectories:YES
                       attributes:nil error:nil];
    NSDictionary *info = @{
        @"CFBundleIdentifier" : @"org.finch.test.panels",
        @"CFBundleExecutable" : @"Test",
        @"CFBundleName" : @"Test",
        @"CFBundlePackageType" : @"APPL"
    };
    [info writeToFile:[tmp stringByAppendingPathComponent:@"Test.app/Contents/Info.plist"] atomically:NO];
    for (NSString *f in @[ @"file.txt", @"image.png", @"Dup/a.txt", @"Dup/b", @"Dup/c.tar.gz", @"Dup/d copy.txt",
                           @"Dup/f copy 3.txt", @"trash-me.txt" ])
        [@"x" writeToFile:[tmp stringByAppendingPathComponent:f] atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

static void
files(void)
{
    NSWorkspace *w = [NSWorkspace sharedWorkspace];
    out(@"NSWorkspace");
    SHOW(@"%d", [NSWorkspace sharedWorkspace] == w);
    SHOW(@"%d", w.notificationCenter != nil);
    SHOW(@"%d", w.notificationCenter != [NSNotificationCenter defaultCenter]);
    SHOW(@"%d", w.notificationCenter == [NSWorkspace sharedWorkspace].notificationCenter);
    make_tree();
    for (NSString *f in @[ @"Plain", @"Test.app", @"X.bundle", @"Thing.foo", @"file.txt", @"missing.app" ])
        out(@"  isFilePackageAtPath %@: %d", f, [w isFilePackageAtPath:[tmp stringByAppendingPathComponent:f]]);
    for (NSString *f in @[ @"Plain", @"Test.app", @"file.txt", @"image.png", @"missing.txt" ]) {
        NSError *e = nil;
        NSString *t = [w typeOfFile:[tmp stringByAppendingPathComponent:f] error:&e];
        out(@"  typeOfFile %@: %@ error %@ %ld", f, t, e.domain, (long)e.code);
    }
    SHOW(@"%@", [w localizedDescriptionForType:@"public.plain-text"]);
    SHOW(@"%@", [w preferredFilenameExtensionForType:@"public.plain-text"]);
    SHOW(@"%@", [w preferredFilenameExtensionForType:@"public.jpeg"]);
    SHOW(@"%d", [w filenameExtension:@"TXT" isValidForType:@"public.plain-text"]);
    SHOW(@"%d", [w filenameExtension:@"png" isValidForType:@"public.plain-text"]);
    SHOW(@"%d", [w type:@"public.plain-text" conformsToType:@"public.data"]);
    SHOW(@"%d", [w type:@"public.data" conformsToType:@"public.plain-text"]);
    SHOW(@"%@", NSStringFromSize([w iconForFile:[tmp stringByAppendingPathComponent:@"file.txt"]].size));
    SHOW(@"%@", NSStringFromSize([w iconForFile:[tmp stringByAppendingPathComponent:@"Plain"]].size));
    SHOW(@"%@", NSStringFromSize([w iconForFile:[tmp stringByAppendingPathComponent:@"Test.app"]].size));
    SHOW(@"%@", NSStringFromSize([w iconForFile:[tmp stringByAppendingPathComponent:@"missing"]].size));
    SHOW(@"%@", NSStringFromSize([w iconForFiles:@[ @"/tmp", tmp ]].size));
    SHOW(@"%@", NSStringFromSize([w iconForContentType:UTTypePlainText].size));
    SHOW(@"%@", NSStringFromSize([w iconForContentType:UTTypeFolder].size));
    SHOW(@"%@", NSStringFromSize([w iconForFileType:@"txt"].size));
    SHOW(@"%@", NSStringFromSize([w iconForFileType:NSDirectoryFileType].size));
    SHOW(@"%@", [w URLForApplicationWithBundleIdentifier:@"org.finch.nonexistent"]);
    SHOW(@"%lu", (unsigned long)[w URLsForApplicationsWithBundleIdentifier:@"org.finch.nonexistent"].count);
    SHOW(@"%@", [w fullPathForApplication:@"No Such Finch App"]);
    SHOW(@"%@", [w absolutePathForAppBundleWithIdentifier:@"org.finch.nonexistent"]);
    SHOW(@"%@", list(w.fileLabels));
    for (NSColor *c in w.fileLabelColors) {
        NSColor *s = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        out(@"  label colour %.3f %.3f %.3f", s.redComponent, s.greenComponent, s.blueComponent);
    }
    SHOW(@"%d", w.accessibilityDisplayShouldReduceMotion);
    SHOW(@"%d", w.accessibilityDisplayShouldIncreaseContrast);
    SHOW(@"%d", w.accessibilityDisplayShouldReduceTransparency);

    out(@"duplicateURLs");
    NSMutableArray *urls = [NSMutableArray array];
    for (NSString *n in @[ @"a.txt", @"b", @"c.tar.gz", @"d copy.txt", @"f copy 3.txt", @"E.app", @"missing" ])
        [urls addObject:[NSURL fileURLWithPath:[[tmp stringByAppendingPathComponent:@"Dup"] stringByAppendingPathComponent:n]]];
    __block BOOL done = NO;
    [w duplicateURLs:urls
        completionHandler:^(NSDictionary<NSURL *, NSURL *> *m, NSError *e) {
            out(@"  on main thread %d", [NSThread isMainThread]);
            NSArray *keys = [m.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSURL *x, NSURL *y) {
                return [x.path compare:y.path];
            }];
            for (NSURL *k in keys)
                out(@"  %@ -> %@", k.lastPathComponent, m[k].lastPathComponent);
            out(@"  error %@ %ld '%@' underlying %lu", e.domain, (long)e.code, e.localizedDescription,
                (unsigned long)[e.userInfo[@"NSUnderlyingErrors"] count]);
            done = YES;
        }];
    while (!done)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    NSArray *names = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:[tmp stringByAppendingPathComponent:@"Dup"]
                                                                          error:nil]
        sortedArrayUsingSelector:@selector(compare:)];
    out(@"  folder now %@", [names componentsJoinedByString:@", "]);
    done = NO;
    [w duplicateURLs:@[ [NSURL fileURLWithPath:[tmp stringByAppendingPathComponent:@"Dup/a.txt"]] ]
        completionHandler:^(NSDictionary<NSURL *, NSURL *> *m, NSError *e) {
            for (NSURL *k in m)
                out(@"  again %@ -> %@ error %@", k.lastPathComponent, m[k].lastPathComponent, e);
            done = YES;
        }];
    while (!done)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

    out(@"recycleURLs");
    done = NO;
    NSString *name = [NSString stringWithFormat:@"finch-panels-test-%d.txt", getpid()];
    NSString *victim = [tmp stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] moveItemAtPath:[tmp stringByAppendingPathComponent:@"trash-me.txt"] toPath:victim
                                             error:nil];
    [w recycleURLs:@[ [NSURL fileURLWithPath:victim] ]
        completionHandler:^(NSDictionary<NSURL *, NSURL *> *m, NSError *e) {
            out(@"  on main thread %d count %lu error %@", [NSThread isMainThread], (unsigned long)m.count, e);
            for (NSURL *k in m) {
                NSURL *to = m[k];
                out(@"  moved to %@/%@ exists %d; source exists %d",
                    to.URLByDeletingLastPathComponent.lastPathComponent, [to.lastPathComponent isEqual:name] ? @"(same name)" : to.lastPathComponent,
                    [[NSFileManager defaultManager] fileExistsAtPath:to.path],
                    [[NSFileManager defaultManager] fileExistsAtPath:victim]);
                [[NSFileManager defaultManager] removeItemAtURL:to error:nil];
            }
            done = YES;
        }];
    while (!done)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        printf("%s\n", class_getImageName([NSAlert class]));
        [NSApplication sharedApplication];
        alerts();
        panels();
        constants();
        running();
        files();
    }
    return 0;
}
