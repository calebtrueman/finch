/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "appkit-color-browser-test.inc"
#import <AppKit/AppKit.h>
#include <stdio.h>
int main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        [NSApplication sharedApplication];
        puts("AppKit color/browser comparison");
        FinchColorBrowserTests();
        if (argc > 1)
            FinchColorBrowserNibTest([NSString stringWithUTF8String:argv[1]]);
    }
    return 0;
}
