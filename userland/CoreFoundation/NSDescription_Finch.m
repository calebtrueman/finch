/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * How collections describe themselves (-description, -descriptionWithLocale:
 * and -descriptionWithLocale:indent: of NSArray, NSDictionary and NSSet),
 * in the old-style property-list text of Apple's, measured on macOS 26:
 *
 *   (                        {                       {(
 *       plain,                   key = value;            x
 *       "two words",             nested =     (      )}
 *           (                        1
 *           in                   );
 *       )                    }
 *   )
 *
 * Each level indents four spaces, and a nested collection, which indents
 * itself, starts after its parent's indentation too. Dictionaries list their
 * keys sorted when every key is a string. Strings are quoted unless they are
 * ASCII letters and digits only; quoted, they escape " \ \a \b \t \n \v \f, and
 * any UTF-16 unit above 0x7e as \Uxxxx. Elements that aren't strings or
 * collections are their -descriptionWithLocale: (or -description), quoted
 * by the same rule, except NSData's, which is never quoted.
 *
 * Apple's CFCopyDescription gives this text for arrays, dictionaries and
 * sets, which are ObjC objects there; Finch's sends -description for those
 * types (patch 0003).
 */
#include "CFObjCClasses_Finch.h"

@interface NSObject (FinchDescription)
- (id)descriptionWithLocale:(id)locale;
- (id)descriptionWithLocale:(id)locale indent:(NSUInteger)level;
@end
@interface NSArray (FinchDescriptionDecls)
- (NSArray *)allObjects;
@end

static void
indent(CFMutableStringRef s, NSUInteger level)
{
    for (NSUInteger i = 0; i < level * 4; i++) CFStringAppend(s, CFSTR(" "));
}

/* Append str, quoted if it must be. */
static void
append_quoted(CFMutableStringRef out, CFStringRef str)
{
    CFIndex n = CFStringGetLength(str);
    BOOL plain = n > 0;
    for (CFIndex i = 0; plain && i < n; i++) {
        UniChar c = CFStringGetCharacterAtIndex(str, i);
        plain = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
    }
    if (plain) {
        CFStringAppend(out, str);
        return;
    }
    CFStringAppend(out, CFSTR("\""));
    for (CFIndex i = 0; i < n; i++) {
        UniChar c = CFStringGetCharacterAtIndex(str, i);
        switch (c) {
        case '"': CFStringAppend(out, CFSTR("\\\"")); break;
        case '\\': CFStringAppend(out, CFSTR("\\\\")); break;
        case '\a': CFStringAppend(out, CFSTR("\\a")); break;
        case '\b': CFStringAppend(out, CFSTR("\\b")); break;
        case '\t': CFStringAppend(out, CFSTR("\\t")); break;
        case '\n': CFStringAppend(out, CFSTR("\\n")); break;
        case '\v': CFStringAppend(out, CFSTR("\\v")); break;
        case '\f': CFStringAppend(out, CFSTR("\\f")); break;
        default:
            if (c > 0x7e && c != 0x7f) CFStringAppendFormat(out, NULL, CFSTR("\\U%04x"), c);
            else CFStringAppendCharacters(out, &c, 1);
            break;
        }
    }
    CFStringAppend(out, CFSTR("\""));
}

static BOOL
is_kind(id o, const char *cls)
{
    Class c = objc_getClass(cls);
    return c && [o isKindOfClass:c];
}

/* Append one element (or key) at nesting `level`. */
static void
append_element(CFMutableStringRef out, id o, id locale, NSUInteger level)
{
    if (is_kind(o, "NSString")) {
        append_quoted(out, (CFStringRef)o);
    } else if ([o respondsToSelector:@selector(descriptionWithLocale:indent:)]) {
        CFStringAppend(out, (CFStringRef)[o descriptionWithLocale:locale indent:level]);
    } else if (is_kind(o, "NSData")) {
        CFStringAppend(out, (CFStringRef)[o description]);
    } else {
        id d = [o respondsToSelector:@selector(descriptionWithLocale:)] ? [o descriptionWithLocale:locale] : [o description];
        append_quoted(out, d ? (CFStringRef)d : CFSTR("(null)"));
    }
}

static CFComparisonResult
compare_keys(const void *a, const void *b, void *context)
{
    return CFStringCompare((CFStringRef)a, (CFStringRef)b, 0);
}

@implementation NSArray (FinchDescription)
- (id)descriptionWithLocale:(id)locale indent:(NSUInteger)level
{
    CFMutableStringRef s = CFStringCreateMutable(NULL, 0);
    indent(s, level);
    CFStringAppend(s, CFSTR("(\n"));
    NSUInteger n = [self count], i = 0;
    for (id o in self) {
        indent(s, level + 1);
        append_element(s, o, locale, level + 1);
        CFStringAppend(s, ++i < n ? CFSTR(",\n") : CFSTR("\n"));
    }
    indent(s, level);
    CFStringAppend(s, CFSTR(")"));
    return [(id)s autorelease];
}
- (id)descriptionWithLocale:(id)locale { return [self descriptionWithLocale:locale indent:0]; }
- (id)description { return [self descriptionWithLocale:nil indent:0]; }
@end

@implementation NSDictionary (FinchDescription)
- (id)descriptionWithLocale:(id)locale indent:(NSUInteger)level
{
    CFMutableStringRef s = CFStringCreateMutable(NULL, 0);
    indent(s, level);
    CFStringAppend(s, CFSTR("{\n"));
    NSUInteger n = [self count];
    id *keys = malloc((n + 1) * sizeof(id));
    NSUInteger k = 0;
    BOOL strings = YES;
    for (id key in self) {
        if (k == n) break;
        keys[k++] = key;
        strings = strings && is_kind(key, "NSString");
    }
    if (strings && k > 1) {
        CFMutableArrayRef sorted = CFArrayCreateMutable(NULL, (CFIndex)k, NULL);
        for (NSUInteger i = 0; i < k; i++) CFArrayAppendValue(sorted, keys[i]);
        CFArraySortValues(sorted, CFRangeMake(0, (CFIndex)k), compare_keys, NULL);
        CFArrayGetValues(sorted, CFRangeMake(0, (CFIndex)k), (const void **)keys);
        CFRelease(sorted);
    }
    for (NSUInteger i = 0; i < k; i++) {
        indent(s, level + 1);
        append_element(s, keys[i], locale, level + 1);
        CFStringAppend(s, CFSTR(" = "));
        append_element(s, [self objectForKey:keys[i]], locale, level + 1);
        CFStringAppend(s, CFSTR(";\n"));
    }
    free(keys);
    indent(s, level);
    CFStringAppend(s, CFSTR("}"));
    return [(id)s autorelease];
}
- (id)descriptionWithLocale:(id)locale { return [self descriptionWithLocale:locale indent:0]; }
- (id)description { return [self descriptionWithLocale:nil indent:0]; }
@end

@implementation NSSet (FinchDescription)
- (id)descriptionWithLocale:(id)locale indent:(NSUInteger)level
{
    CFMutableStringRef s = CFStringCreateMutable(NULL, 0);
    indent(s, level);
    CFStringAppend(s, CFSTR("{(\n"));
    NSUInteger n = [self count], i = 0;
    for (id o in self) {
        indent(s, level + 1);
        append_element(s, o, locale, level + 1);
        CFStringAppend(s, ++i < n ? CFSTR(",\n") : CFSTR("\n"));
    }
    indent(s, level);
    CFStringAppend(s, CFSTR(")}"));
    return [(id)s autorelease];
}
- (id)descriptionWithLocale:(id)locale { return [self descriptionWithLocale:locale indent:0]; }
- (id)description { return [self descriptionWithLocale:nil indent:0]; }
@end
