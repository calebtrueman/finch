/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSText: the abstract text-editing view NSTextView implements. As on
 * macOS, [NSText alloc] makes an NSTextView. Its notification names and
 * the NSTextMovement key live here.
 */
#import "AppKit_Finch.h"

NSNotificationName NSTextDidBeginEditingNotification = @"NSTextDidBeginEditingNotification";
NSNotificationName NSTextDidEndEditingNotification = @"NSTextDidEndEditingNotification";
NSNotificationName NSTextDidChangeNotification = @"NSTextDidChangeNotification";
NSString *const NSTextMovementUserInfoKey = @"NSTextMovement";
NSNotificationName NSTextViewWillSwitchToNSLayoutManagerNotification =
    @"NSTextViewWillSwitchToNSLayoutManagerNotification";
NSNotificationName NSTextViewDidSwitchToNSLayoutManagerNotification =
    @"NSTextViewDidSwitchToNSLayoutManagerNotification";

@implementation NSText

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    if (self == [NSText class])
        return [NSTextView allocWithZone:zone];
    return [super allocWithZone:zone];
}

@end
