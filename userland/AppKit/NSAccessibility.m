/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The accessibility functions (NSAccessibility.h). Finch has no
 * accessibility server yet, so posting notifications goes nowhere; the
 * element-tree helpers work on the objects they're given, as Apple's do.
 */
#import "NSView_Finch.h"

void
NSAccessibilityPostNotification(id element, NSAccessibilityNotificationName notification)
{
}

void
NSAccessibilityPostNotificationWithUserInfo(id element, NSAccessibilityNotificationName notification,
                                            NSDictionary<NSAccessibilityNotificationUserInfoKey, id> *userInfo)
{
}

NSRect
NSAccessibilityFrameInView(NSView *parentView, NSRect frame)
{
    NSRect inWindow = [parentView convertRect:frame toView:nil];
    return [[parentView window] convertRectToScreen:inWindow];
}

NSPoint
NSAccessibilityPointInView(NSView *parentView, NSPoint point)
{
    NSPoint inWindow = [parentView convertPoint:point toView:nil];
    return [[parentView window] convertPointToScreen:inWindow];
}

BOOL
NSAccessibilitySetMayContainProtectedContent(BOOL flag)
{
    return YES;
}

NSString *
NSAccessibilityRoleDescription(NSAccessibilityRole role, NSAccessibilitySubrole subrole)
{
    if (!role)
        return nil;
    /* "AXButton" -> "button" */
    NSString *r = [role hasPrefix:@"AX"] ? [role substringFromIndex:2] : role;
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < [r length]; i++) {
        unichar c = [r characterAtIndex:i];
        if (i && c >= 'A' && c <= 'Z')
            [out appendString:@" "];
        [out appendFormat:@"%C", (unichar)tolower(c)];
    }
    return out;
}

NSString *
NSAccessibilityRoleDescriptionForUIElement(id element)
{
    return NSAccessibilityRoleDescription([element respondsToSelector:@selector(accessibilityRole)]
                                              ? [element accessibilityRole]
                                              : nil,
                                          nil);
}

NSString *
NSAccessibilityActionDescription(NSAccessibilityActionName action)
{
    return NSAccessibilityRoleDescription(action, nil);
}

void
NSAccessibilityRaiseBadArgumentException(id element, NSAccessibilityAttributeName attribute, id value)
{
    [NSException raise:NSAccessibilityException
                format:@"Bad argument for attribute %@ of %@: %@", attribute, element, value];
}

static BOOL
ignored(id element)
{
    return [element respondsToSelector:@selector(isAccessibilityElement)] && ![element isAccessibilityElement];
}

id
NSAccessibilityUnignoredAncestor(id element)
{
    while (element && ignored(element))
        element = [element respondsToSelector:@selector(accessibilityParent)] ? [element accessibilityParent] : nil;
    return element;
}

id
NSAccessibilityUnignoredDescendant(id element)
{
    while (element && ignored(element)) {
        NSArray *children = [element respondsToSelector:@selector(accessibilityChildren)] ? [element accessibilityChildren]
                                                                                           : nil;
        element = [children count] == 1 ? children[0] : nil;
    }
    return element;
}

NSArray *
NSAccessibilityUnignoredChildren(NSArray *originalChildren)
{
    NSMutableArray *out = [NSMutableArray array];
    for (id child in originalChildren) {
        if (!ignored(child))
            [out addObject:child];
        else if ([child respondsToSelector:@selector(accessibilityChildren)])
            [out addObjectsFromArray:NSAccessibilityUnignoredChildren([child accessibilityChildren])];
    }
    return out;
}

NSArray *
NSAccessibilityUnignoredChildrenForOnlyChild(id originalChild)
{
    return NSAccessibilityUnignoredChildren(originalChild ? @[ originalChild ] : @[]);
}
