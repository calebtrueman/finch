/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import "NSControl_Finch.h"

@interface NSFormCell (FinchForm)
- (CGFloat)_finchNaturalTitleWidth;
- (void)_finchSetSharedTitleWidth:(CGFloat)width;
@end

@implementation NSForm {
    CGFloat _preferredWidth;
}
- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame mode:NSTrackModeMatrix cellClass:[NSFormCell class] numberOfRows:0 numberOfColumns:0])) {
        [self setCellSize:NSMakeSize(frame.size.width, 0)]; _preferredWidth = -1;
    }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) _preferredWidth = [coder containsValueForKey:@"NSPreferredTextFieldWidth"] ? [coder decodeDoubleForKey:@"NSPreferredTextFieldWidth"] : -1;
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder { [super encodeWithCoder:coder]; [coder encodeDouble:_preferredWidth forKey:@"NSPreferredTextFieldWidth"]; }
- (NSInteger)indexOfSelectedItem { return [self selectedRow]; }
- (id)cellAtIndex:(NSInteger)index { return [self cellAtRow:index column:0]; }
- (void)drawCellAtIndex:(NSInteger)index { [self drawCellAtRow:index column:0]; }
- (NSFormCell *)addEntry:(NSString *)title { return [self insertEntry:title atIndex:[self numberOfRows]]; }
- (NSFormCell *)insertEntry:(NSString *)title atIndex:(NSInteger)index
{
    NSFormCell *cell = [self prototype] ? [[self prototype] copy] : [[[self cellClass] alloc] initTextCell:title];
    [cell setTitle:title]; [cell setPreferredTextFieldWidth:_preferredWidth];
    [self insertRow:index withCells:@[cell]]; [cell release]; [self _finchAlignTitles]; return [self cellAtIndex:index];
}
- (void)removeEntryAtIndex:(NSInteger)index { [self removeRow:index]; [self _finchAlignTitles]; }
- (NSInteger)indexOfCellWithTag:(NSInteger)tag
{
    NSInteger row, column; return [self getRow:&row column:&column ofCell:[self cellWithTag:tag]] ? row : -1;
}
- (void)selectTextAtIndex:(NSInteger)index { [self selectTextAtRow:index column:0]; }
- (void)setEntryWidth:(CGFloat)width { NSSize size = [self cellSize]; size.width = width; [self setCellSize:size]; }
- (void)setInterlineSpacing:(CGFloat)spacing { NSSize size = [self intercellSpacing]; size.height = spacing; [self setIntercellSpacing:size]; }
- (void)setBordered:(BOOL)b { [[self prototype] setBordered:b]; for (NSCell *cell in [self cells]) [cell setBordered:b]; }
- (void)setBezeled:(BOOL)b { [[self prototype] setBezeled:b]; for (NSCell *cell in [self cells]) [cell setBezeled:b]; }
- (void)setTitleAlignment:(NSTextAlignment)a { [(NSFormCell *)[self prototype] setTitleAlignment:a]; for (NSFormCell *cell in [self cells]) [cell setTitleAlignment:a]; }
- (void)setTextAlignment:(NSTextAlignment)a { [[self prototype] setAlignment:a]; for (NSCell *cell in [self cells]) [cell setAlignment:a]; }
- (void)setTitleFont:(NSFont *)font { [(NSFormCell *)[self prototype] setTitleFont:font]; for (NSFormCell *cell in [self cells]) [cell setTitleFont:font]; [self _finchAlignTitles]; }
- (void)setTextFont:(NSFont *)font { [self setFont:font]; }
- (void)setTitleBaseWritingDirection:(NSWritingDirection)d { [(NSFormCell *)[self prototype] setTitleBaseWritingDirection:d]; for (NSFormCell *cell in [self cells]) [cell setTitleBaseWritingDirection:d]; }
- (void)setTextBaseWritingDirection:(NSWritingDirection)d { [[self prototype] setBaseWritingDirection:d]; for (NSCell *cell in [self cells]) [cell setBaseWritingDirection:d]; }
- (CGFloat)preferredTextFieldWidth { return [(NSFormCell *)[self prototype] preferredTextFieldWidth]; }
- (void)setPreferredTextFieldWidth:(CGFloat)width
{
    _preferredWidth = width; [(NSFormCell *)[self prototype] setPreferredTextFieldWidth:width];
    for (NSFormCell *cell in [self cells]) [cell setPreferredTextFieldWidth:width]; [self invalidateIntrinsicContentSize];
}
- (void)_finchAlignTitles
{
    CGFloat width = 0; for (NSFormCell *cell in [self cells]) width = MAX(width, [cell _finchNaturalTitleWidth]);
    for (NSFormCell *cell in [self cells]) [cell _finchSetSharedTitleWidth:width];
}
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; NSSize cell = [self cellSize]; cell.width = size.width; [self setCellSize:cell]; }
- (void)sizeToCells
{
    [self _finchAlignTitles]; NSSize size = [self cellSize];
    for (NSFormCell *cell in [self cells]) { NSSize entry = [cell cellSize]; size.height = MAX(size.height, entry.height); if (_preferredWidth >= 0) size.width = MAX(size.width, entry.width); }
    [self setCellSize:size]; [super sizeToCells];
}
- (void)drawRect:(NSRect)dirty { [self _finchAlignTitles]; [super drawRect:dirty]; }
@end
