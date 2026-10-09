/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef NSTOKENFIELD_FINCH_H
#define NSTOKENFIELD_FINCH_H
#import "NSControl_Finch.h"

FINCH_PRIVATE extern NSString *const FinchTokenObjectAttribute;
@interface NSTokenFieldCell (FinchTokens)
- (NSString *)_finchDisplayString:(id)object;
- (NSString *)_finchEditingString:(id)object;
- (id)_finchRepresentedObject:(NSString *)string;
- (NSArray *)_finchShouldAdd:(NSArray *)objects atIndex:(NSUInteger)index;
- (NSTokenStyle)_finchStyleForObject:(id)object;
- (NSMenu *)_finchMenuForObject:(id)object;
- (NSAttributedString *)_finchTokenString:(NSArray *)objects;
- (NSArray *)_finchObjectsFromString:(NSAttributedString *)string;
- (BOOL)_finchTokenizeEditor:(NSTextView *)editor finish:(BOOL)finish;
- (NSArray *)_finchCompletions:(NSString *)string index:(NSInteger)index selected:(NSInteger *)selected;
@end
@interface NSTokenField (FinchTokens)
- (void)_finchRequestCompletions;
- (void)_finchComplete:(id)sender;
@end
#endif
