/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import "NSPathControl_Finch.h"

@implementation NSPathControlItem {
    NSPathComponentCell *_component;
}
- (instancetype)init { return [self _finchInitWithCell:[[[NSPathComponentCell alloc] initTextCell:@""] autorelease]]; }
- (instancetype)_finchInitWithCell:(NSPathComponentCell *)cell
{
    if ((self = [super init])) _component = [cell retain]; return self;
}
- (void)dealloc { [_component release]; [super dealloc]; }
- (NSPathComponentCell *)_finchCell { return _component; }
- (NSString *)title { return [_component stringValue]; }
- (void)setTitle:(NSString *)title { [_component setStringValue:title ?: @""]; }
- (NSAttributedString *)attributedTitle { return [_component attributedStringValue]; }
- (void)setAttributedTitle:(NSAttributedString *)title { [_component setAttributedStringValue:title]; }
- (NSImage *)image { return [_component image]; }
- (void)setImage:(NSImage *)image { [_component setImage:image]; }
- (NSURL *)URL { return [_component URL]; }
@end
