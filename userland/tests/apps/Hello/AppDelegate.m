/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) IBOutlet NSWindow *window;
@property (strong) IBOutlet NSTextField *nameField;
@property (strong) IBOutlet NSTextField *greeting;
@property (strong) IBOutlet NSButton *loud;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    printf("Hello: launched, window '%s', menu items %ld\n", self.window.title.UTF8String,
           (long)NSApp.mainMenu.numberOfItems);
    fflush(stdout);
}

- (IBAction)greet:(id)sender
{
    NSString *name = self.nameField.stringValue.length ? self.nameField.stringValue : @"world";
    NSString *s = [NSString stringWithFormat:@"Hello, %@%@", name, self.loud.state == NSControlStateValueOn ? @"!" : @"."];
    self.greeting.stringValue = s;
    printf("Hello: %s\n", s.UTF8String);
    fflush(stdout);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)note
{
    printf("Hello: terminating\n");
    fflush(stdout);
}

@end
