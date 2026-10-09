/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import "AppKit_Finch.h"
@implementation NSColorPicker {
    __weak NSColorPanel *_panel;
}
- (instancetype)initWithPickerMask:(NSUInteger)mask colorPanel:(NSColorPanel *)panel
{
    if ((self = [super init]))
        _panel = panel;
    return self;
}
- (NSColorPanel *)colorPanel
{
    return _panel;
}
- (NSImage *)provideNewButtonImage
{
    NSString *path = [[NSBundle bundleForClass:[self class]] pathForResource:NSStringFromClass([self class])
                                                                      ofType:@"tiff"];
    return path ? [[[NSImage alloc] initWithContentsOfFile:path] autorelease] : nil;
}
- (void)insertNewButtonImage:(NSImage *)image in:(NSButtonCell *)cell
{
    cell.image = image;
}
- (void)viewSizeChanged:(id)sender
{
}
- (void)alphaControlAddedOrRemoved:(id)sender
{
}
- (void)attachColorList:(NSColorList *)list
{
}
- (void)detachColorList:(NSColorList *)list
{
}
- (void)setMode:(NSColorPanelMode)mode
{
}
- (NSString *)buttonToolTip
{
    return NSStringFromClass([self class]);
}
- (NSSize)minContentSize
{
    return [(id<NSColorPickingCustom>)self provideNewView:NO].frame.size;
}
@end
