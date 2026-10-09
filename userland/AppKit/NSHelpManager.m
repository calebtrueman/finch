/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Per-object help text; showing a Help Viewer still requires a host service. */
#import "AppKit_Finch.h"
#import <objc/runtime.h>
static char helpKey;
static BOOL contextHelpMode;
@implementation NSHelpManager
+ (NSHelpManager *)sharedHelpManager
{
    static NSHelpManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      manager = [[self alloc] init];
    });
    return manager;
}
+ (BOOL)isContextHelpModeActive
{
    return contextHelpMode;
}
+ (void)setContextHelpModeActive:(BOOL)active
{
    contextHelpMode = active;
}
- (void)setContextHelp:(NSAttributedString *)text forObject:(id)object
{
    if (object)
        objc_setAssociatedObject(object, &helpKey, text, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (void)removeContextHelpForObject:(id)object
{
    if (object)
        objc_setAssociatedObject(object, &helpKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (NSAttributedString *)contextHelpForObject:(id)object
{
    return object ? objc_getAssociatedObject(object, &helpKey) : nil;
}
- (BOOL)showContextHelpForObject:(id)object locationHint:(NSPoint)point
{
    return NO;
}
- (void)openHelpAnchor:(NSHelpAnchorName)anchor inBook:(NSHelpBookName)book
{
}
- (void)findString:(NSString *)query inBook:(NSHelpBookName)book
{
}
- (BOOL)registerBooksInBundle:(NSBundle *)bundle
{
    return NO;
}
@end
