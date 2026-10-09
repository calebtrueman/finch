/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef NSPATHCONTROL_FINCH_H
#define NSPATHCONTROL_FINCH_H
#import "NSControl_Finch.h"
@interface NSPathControlItem (FinchPathItems)
- (instancetype)_finchInitWithCell:(NSPathComponentCell *)cell;
- (NSPathComponentCell *)_finchCell;
@end
@interface NSPathCell (FinchPaths)
- (void)_finchSetClickedCell:(NSPathComponentCell *)cell;
@end
#endif
