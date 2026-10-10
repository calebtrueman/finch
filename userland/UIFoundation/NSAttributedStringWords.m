/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSAttributedString's word and URL finding (AppKit's additions), as Apple's behaves,
 * measured on macOS 26:
 *   - -doubleClickAtIndex: a word is letters and digits, with "_", and "." or "'"
 *     between two of them, inside it ("foo_bar.baz", "3.14", "it's"); a run of spaces
 *     is one piece; any other character stands alone;
 *   - -nextWordFromIndex:forward: the end of the next word, or the start of the
 *     previous one;
 *   - -URLAtIndex:effectiveRange: the URL written in the text at the index (not a link
 *     attribute), within the run of non-space characters there, trimmed of the
 *     punctuation after it (not before it, as Apple's); the range is that run.
 */
#import <AppKit/AppKit.h>

static BOOL
is_word(unichar c)
{
    return [[NSCharacterSet alphanumericCharacterSet] characterIsMember:c] || c == '_';
}

static BOOL
is_space(unichar c)
{
    return [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c];
}

/* Whether the character at i joins the word: a word character, or "." / "'" with word
   characters on both sides. */
static BOOL
joins(NSString *s, NSUInteger i, NSUInteger n)
{
    unichar c = [s characterAtIndex:i];
    if (is_word(c))
        return YES;
    if ((c == '.' || c == '\'' || c == 0x2019) && i > 0 && i + 1 < n)
        return is_word([s characterAtIndex:i - 1]) && is_word([s characterAtIndex:i + 1]);
    return NO;
}

static NSRange
word_range(NSString *s, NSUInteger index)
{
    NSUInteger n = [s length];
    if (!n)
        return NSMakeRange(0, 0);
    if (index >= n)
        index = n - 1;
    unichar c = [s characterAtIndex:index];
    NSUInteger a = index, b = index + 1;
    if (joins(s, index, n)) {
        while (a > 0 && joins(s, a - 1, n))
            a--;
        while (b < n && joins(s, b, n))
            b++;
    } else if (is_space(c)) {
        while (a > 0 && is_space([s characterAtIndex:a - 1]))
            a--;
        while (b < n && is_space([s characterAtIndex:b]))
            b++;
    } else {
        NSRange composed = [s rangeOfComposedCharacterSequenceAtIndex:index];
        return composed;
    }
    return NSMakeRange(a, b - a);
}

@implementation NSAttributedString (FinchWords)

- (NSRange)doubleClickAtIndex:(NSUInteger)location
{
    return word_range([self string], location);
}

- (NSUInteger)nextWordFromIndex:(NSUInteger)location forward:(BOOL)isForward
{
    NSString *s = [self string];
    NSUInteger n = [s length];
    if (isForward) {
        NSUInteger i = location;
        while (i < n && !joins(s, i, n))
            i++;
        while (i < n && joins(s, i, n))
            i++;
        return i;
    }
    if (location == 0)
        return 0;
    NSUInteger i = MIN(location, n) - 1;
    while (i > 0 && !joins(s, i, n))
        i--;
    while (i > 0 && joins(s, i - 1, n))
        i--;
    return i;
}

- (NSURL *)URLAtIndex:(NSUInteger)location effectiveRange:(NSRangePointer)effectiveRange
{
    NSString *s = [self string];
    NSUInteger n = [s length];
    if (location >= n) {
        if (effectiveRange)
            *effectiveRange = NSMakeRange(NSNotFound, 0);
        return nil;
    }
    if (is_space([s characterAtIndex:location])) {
        if (effectiveRange)
            *effectiveRange = NSMakeRange(location, 1);
        return nil;
    }
    NSUInteger a = location, b = location + 1;
    while (a > 0 && !is_space([s characterAtIndex:a - 1]))
        a--;
    while (b < n && !is_space([s characterAtIndex:b]))
        b++;
    NSCharacterSet *trailing = [NSCharacterSet characterSetWithCharactersInString:@".,;:!?)]}>\"'”’"];
    while (b > a + 1 && [trailing characterIsMember:[s characterAtIndex:b - 1]] && b - 1 > location)
        b--;
    NSRange r = NSMakeRange(a, b - a);
    if (effectiveRange)
        *effectiveRange = r;
    NSString *text = [s substringWithRange:r];
    NSRange scheme = [text rangeOfString:@"://"];
    if (scheme.location != NSNotFound && scheme.location > 0)
        return [NSURL URLWithString:text];
    if ([text hasPrefix:@"mailto:"])
        return [NSURL URLWithString:text];
    if ([[text lowercaseString] hasPrefix:@"www."])
        return [NSURL URLWithString:[@"http://" stringByAppendingString:text]];
    return nil;
}

@end
