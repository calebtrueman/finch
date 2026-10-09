/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Apple's font names and the fonts Finch ships in their place: the table
 * CoreText and CoreGraphics resolve names with (userland/fonts/FinchFonts.h). */
#import "UIFoundationInternal.h"
#include "fonts/FinchFonts.h"

NSString *
UIFFontAlias(NSString *name)
{
    const char *alias = name ? finch_font_alias(name.UTF8String) : NULL;
    return alias ? [NSString stringWithUTF8String:alias] : nil;
}

NSString *
UIFAppleFontName(NSString *finchName)
{
    const char *apple = finchName ? finch_font_apple_name(finchName.UTF8String) : NULL;
    return apple ? [NSString stringWithUTF8String:apple] : nil;
}
